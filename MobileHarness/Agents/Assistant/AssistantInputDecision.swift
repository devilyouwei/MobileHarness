import AgentCore
import Foundation
import ModelKit
import ModelKitDefaults
import Synchronization
import UI

public struct InputDecisionOutcome: Sendable, Equatable {
    public enum Route: String, Sendable {
        case local = "local:d3-edge"
        case vela = "local:vela3-fast"
        case vela31 = "local:vela3.1-fast"
        case laya = "local:laya-multilingual"
        case gemma = "local:gemma4-e2b"
        case apple = "local:apple-system"
        case cloud = "cloud:decision"
        case failed = "decision:failed"
    }
    public let route: Route
    public let modelResult: Bool?
    public var signalStatus: String = "not_requested"
    public var reason: String?
    public let requests: [String]
    public enum Failure: String, Sendable {
        case settings = "Could not read Decision settings. Input queued."
        case request = "Could not prepare the Decision request. Input queued."
        case unavailable =
            "The selected Decision model is unavailable. Download it in Agent Models or check its provider. Input queued."
        case notReady = "The selected Decision model is not ready. Input queued."
        case timedOut = "The selected Decision model timed out. Input queued."
        case model = "The selected Decision model failed or returned an invalid result. Input queued."
    }
    public var failure: Failure? = nil
    public var modelName: String? = nil
}

/// Frozen at admission: current user/reply and latest input; no queue or runtime state.
public struct InputDecisionSnapshot: Sendable {
    public struct Exchange: Sendable, Equatable, Codable {
        public let user: String
        public let assistant: String
        public init(user: String, assistant: String) {
            self.user = user
            self.assistant = assistant
        }
    }
    public let input: AgentInput
    public let text: String
    public let currentTurn: Exchange?
    public let receivedAt: ContinuousClock.Instant
    public init(
        input: AgentInput, text: String, currentTurn: Exchange? = nil,
        receivedAt: ContinuousClock.Instant = .now
    ) {
        self.input = input
        self.text = text
        self.currentTurn = currentTurn
        self.receivedAt = receivedAt
    }
    func request() throws -> NoulRequest {
        struct State: Encodable {
            enum CodingKeys: String, CodingKey {
                case currentTurn = "current_turn"
                case incomingUserInput = "incoming_user_input"
            }
            let currentTurn: Exchange?
            let incomingUserInput: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(
            decoding: try encoder.encode(State(currentTurn: currentTurn, incomingUserInput: text)), as: UTF8.self)
        return try NoulRequest(
            text: text, instructions: AgentPrompts.text("Assistant/InputDecision", "question"),
            context: .init(requestID: input.id + ".decision", scopeID: input.sessionID))
    }
}

/// Root-owned bounded classification and cleanup. A timeout retires its result, not its native resource.
public actor AssistantInputDecision {
    private let localModel: @Sendable (String) -> (any ModelDecisionProviding)?
    private let localChatModel: @Sendable (String) async throws -> any ChatCapability
    private var activeLocalID: String?
    private var localMaintenance: Set<String> = []
    private var switchingLocal = false
    public typealias Configuration = (useLocal: Bool, cloud: (@Sendable () async throws -> any ChatCapability)?)
    typealias SelectedConfiguration = (localID: String?, cloud: (@Sendable () async throws -> ChatModel)?)
    private let configuration: @Sendable () async throws -> SelectedConfiguration
    private let report: @Sendable (String) async -> Void
    private let language: @Sendable () -> String
    private let timeout: Duration
    private let localTimeout: Duration
    private let localChatTimeout: Duration
    private var workers: [String: Task<Void, Never>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private enum Attempt: Sendable {
        case selected(Bool)
        case failed(String, InputDecisionOutcome.Failure = .model)
    }
    private var waiters: [String: CheckedContinuation<Attempt, Never>] = [:]
    private var localFailure: String?
    private var preparation: Task<Void, Never>?
    private var stopped = false
    public init(
        local: any ModelDecisionProviding,
        selection: @escaping @Sendable () async throws -> Bool,
        cloud: @escaping @Sendable () async throws -> any ChatCapability,
        report: @escaping @Sendable (String) async -> Void = { _ in },
        language: @escaping @Sendable () -> String = { "en" }
    ) {
        self.init(local: local, configuration: { (try await selection(), cloud) }, report: report, language: language)
    }
    public init(
        local: any ModelDecisionProviding,
        configuration: @escaping @Sendable () async throws -> Configuration,
        report: @escaping @Sendable (String) async -> Void = { _ in },
        language: @escaping @Sendable () -> String = { "en" }
    ) {
        self.init(
            local: local, configuration: configuration, timeout: .seconds(2), localTimeout: .seconds(1),
            report: report, language: language)
    }

    init(
        local: any ModelDecisionProviding,
        configuration: @escaping @Sendable () async throws -> Configuration,
        timeout: Duration, localTimeout: Duration,
        report: @escaping @Sendable (String) async -> Void = { _ in },
        language: @escaping @Sendable () -> String = { "en" }
    ) {
        self.init(
            localModel: { _ in local },
            selectedConfiguration: {
                let result = try await configuration()
                let cloud = result.cloud.map { factory in
                    { @Sendable in ChatModel(capability: try await factory()) }
                }
                return (result.useLocal ? "d3-edge" : nil, cloud)
            }, timeout: timeout, localTimeout: localTimeout, report: report, language: language)
    }

    init(
        localModel: @escaping @Sendable (String) -> (any ModelDecisionProviding)?,
        localChatModel: @escaping @Sendable (String) async throws -> any ChatCapability = { _ in
            throw CapabilityError.unavailable("Local Chat Decision is unavailable")
        },
        selectedConfiguration: @escaping @Sendable () async throws -> SelectedConfiguration,
        timeout: Duration = .seconds(2), localTimeout: Duration = .seconds(1),
        localChatTimeout: Duration = .milliseconds(500),
        report: @escaping @Sendable (String) async -> Void = { _ in },
        language: @escaping @Sendable () -> String = { "en" }
    ) {
        self.localModel = localModel
        self.localChatModel = localChatModel
        self.configuration = selectedConfiguration
        self.report = report
        self.language = language
        self.timeout = timeout
        self.localTimeout = localTimeout
        self.localChatTimeout = localChatTimeout
    }

    public func resetLocalFailure() { localFailure = nil }
    func quiesceLocal(_ id: String) async {
        guard activeLocalID == id else { return }
        localMaintenance.insert(id)
        defer { localMaintenance.remove(id) }
        await joinLocal()
    }

    private func joinLocal() async {
        preparation?.cancel()
        cancel("local")
        await preparation?.value
        await workers["local"]?.value
    }

    private func selectLocal(_ id: String?) async -> String? {
        guard !switchingLocal else { return "Decision model is still switching" }
        guard id != activeLocalID else { return nil }
        switchingLocal = true
        defer { switchingLocal = false }
        if let previous = activeLocalID, !localMaintenance.contains(previous) {
            await joinLocal()
            if let model = localModel(previous), !localMaintenance.contains(previous) {
                do { try await model.unload() } catch {
                    return "Could not release previous Decision model: \(error.localizedDescription)"
                }
            }
        }
        activeLocalID = id
        localFailure = nil
        return nil
    }
    public func stop() async {
        stopped = true
        for timer in timers.values { timer.cancel() }
        for waiter in waiters.values { waiter.resume(returning: .failed("Classification cancelled")) }
        waiters.removeAll()
        let active = Array(workers.values)
        for task in active { task.cancel() }
        preparation?.cancel()
        for task in active { await task.value }
        await preparation?.value
    }
    public func classify(_ snapshot: InputDecisionSnapshot) async -> InputDecisionOutcome {
        await AgentPrompts.$language.withValue(AgentPrompts.normalizedLanguage(language())) {
            await classifyInput(snapshot)
        }
    }

    private func classifyInput(_ snapshot: InputDecisionSnapshot) async -> InputDecisionOutcome {
        let requests = Mutex<[String]>([])
        let selectedModelName = Mutex<String?>(nil)
        var localFailureReason: String?
        var localFailureKind: InputDecisionOutcome.Failure = .model
        func failedOutcome(_ reason: String, failure: InputDecisionOutcome.Failure? = nil) -> InputDecisionOutcome {
            .init(
                route: .failed, modelResult: nil,
                reason: reason,
                requests: requests.withLock { $0 }, failure: failure, modelName: selectedModelName.withLock { $0 })
        }
        guard !stopped, !Task.isCancelled else { return failedOutcome("Classification cancelled") }
        let deadline = snapshot.receivedAt.advanced(by: timeout)
        guard ContinuousClock.now < deadline else {
            return failedOutcome("Classification timed out", failure: .timedOut)
        }
        let route: SelectedConfiguration
        do { route = try await configuration() } catch {
            guard !stopped, !Task.isCancelled, !(error is CancellationError) else {
                return failedOutcome("Classification cancelled")
            }
            await reportFailure(.settings)
            return failedOutcome("Could not read Decision settings: \(error.localizedDescription)", failure: .settings)
        }
        selectedModelName.withLock {
            $0 = route.localID.map { id in
                switch id {
                case "d3-edge": "D3 Edge"
                case "vela3-fast": "Vela 3 Fast"
                case "vela3.1-fast": "Vela 3.1 Fast"
                case "laya-multilingual": "Laya Multilingual"
                case "gemma4-e2b": "Gemma 4 E2B"
                case "apple-system": "Apple System LLM"
                default: id
                }
            }
        }
        let prompt: NoulRequest
        do {
            prompt = try snapshot.request()
        } catch {
            await reportFailure(.request)
            return failedOutcome("Could not prepare Decision request: \(error.localizedDescription)", failure: .request)
        }
        if let reason = await selectLocal(route.localID) {
            guard !stopped, !Task.isCancelled else { return failedOutcome("Classification cancelled") }
            await reportFailure(.model)
            return failedOutcome(reason, failure: .model)
        }
        if let id = route.localID, id == "gemma4-e2b" || id == "apple-system" {
            let modelName = id == "apple-system" ? "Apple System LLM" : "Gemma 4 E2B"
            let modelRoute: InputDecisionOutcome.Route = id == "apple-system" ? .apple : .gemma
            guard !localMaintenance.contains(id), activeLocalID == id else {
                await reportFailure(.unavailable)
                return failedOutcome("Local Chat model temporarily unavailable", failure: .unavailable)
            }
            let resolve = localChatModel
            let result = await race(
                "local", until: min(deadline, .now.advanced(by: localChatTimeout)),
                name: modelName
            ) {
                let model = try await resolve(id)
                if case .unavailable(let reason) = await model.availability {
                    throw CapabilityError.unavailable(reason)
                }
                return try await Self.read(ChatDecision(model), request: prompt) { request in
                    requests.withLock { $0.append("Local \(modelName)\n\n" + request) }
                }
            }
            switch result {
            case .selected(let action):
                await report("Local \(modelName)")
                return outcome(
                    action, route: modelRoute, snapshot: snapshot, requests: requests.withLock { $0 },
                    modelName: selectedModelName.withLock { $0 })
            case .failed(let reason, let failure):
                if !stopped, !Task.isCancelled { await reportFailure(failure) }
                return failedOutcome(reason, failure: failure)
            }
        }
        let modelName = selectedModelName.withLock { $0 } ?? "Decision"
        let modelRoute: InputDecisionOutcome.Route =
            switch route.localID {
            case "vela3-fast": .vela
            case "vela3.1-fast": .vela31
            case "laya-multilingual": .laya
            default: .local
            }
        if let id = route.localID {
            localFailureReason = localFailure
            if switchingLocal || activeLocalID != id || localMaintenance.contains(id) {
                localFailureReason = "Decision resources are being released"
                localFailureKind = .notReady
            } else if localModel(id) == nil {
                localFailureReason = "Selected local Decision model is unavailable"
                localFailureKind = .unavailable
            }
        }
        if let id = route.localID, let local = localModel(id), localFailureReason == nil, !stopped, !Task.isCancelled {
            do {
                let status = try await local.status()
                if localMaintenance.contains(id) || activeLocalID != id || switchingLocal || stopped || Task.isCancelled
                {
                    localFailureReason = "Decision resources are being released"
                    localFailureKind = .notReady
                } else if status == .ready {
                    await report(AppLanguage(preferredLanguage: language()).format("Local · %@", modelName))
                    let result = await race("local", until: min(deadline, .now.advanced(by: localTimeout))) {
                        try Task.checkCancellation()
                        return try await Self.read(local, request: prompt) { request in
                            requests.withLock { $0.append("Local \(modelName)\n\n" + request) }
                        }
                    }
                    switch result {
                    case .selected(let action):
                        return outcome(
                            action, route: modelRoute, snapshot: snapshot, requests: requests.withLock { $0 },
                            modelName: selectedModelName.withLock { $0 })
                    case .failed(let reason, let failure):
                        localFailureReason = reason
                        localFailureKind = failure
                    }
                } else {
                    localFailureReason = "\(modelName) is not ready (\(status.rawValue))"
                    localFailureKind = .notReady
                    if preparation == nil {
                        preparation = Task {
                            do { try await local.warmup() } catch
                                where !Task.isCancelled && !(error is CancellationError)
                            {
                                self.localFailure = "Decision preparation failed: \(error.localizedDescription)"
                                await self.reportFailure(.model)
                            } catch {}
                            self.preparation = nil
                        }
                    }
                }
            } catch {
                localFailureReason = "Could not read Decision status: \(error.localizedDescription)"
            }
        }
        guard !stopped, !Task.isCancelled else { return failedOutcome("Classification cancelled") }
        if route.localID != nil {
            let reason = localFailureReason ?? "Selected local Decision model is unavailable"
            await reportFailure(localFailureKind)
            return failedOutcome(reason, failure: localFailureKind)
        }
        guard ContinuousClock.now < deadline else {
            await reportFailure(.timedOut)
            return failedOutcome("Classification timed out", failure: .timedOut)
        }
        guard let cloud = route.cloud else {
            await reportFailure(.unavailable)
            return failedOutcome("Cloud Decision is unconfigured", failure: .unavailable)
        }
        await report(AppLanguage(preferredLanguage: language()).text("Cloud · Selected Decision model"))
        let result = await race("cloud", until: deadline) {
            let model = try await cloud()
            selectedModelName.withLock { $0 = model.modelName }
            return try await Self.read(ChatDecision(model.capability), request: prompt) { request in
                requests.withLock { $0.append("Cloud Decision\n\n" + request) }
            }
        }
        if case .selected(let action) = result {
            return outcome(
                action, route: .cloud, snapshot: snapshot, requests: requests.withLock { $0 },
                modelName: selectedModelName.withLock { $0 })
        }
        if stopped || Task.isCancelled { return failedOutcome("Classification cancelled") }
        if case .failed(let reason, let failure) = result {
            await reportFailure(failure)
            return failedOutcome(reason, failure: failure)
        }
        return failedOutcome("Model returned no valid classification", failure: .model)
    }

    private func reportFailure(_ failure: InputDecisionOutcome.Failure) async {
        await report(AppLanguage(preferredLanguage: language()).text(failure.rawValue))
    }

    private static func read(
        _ model: any DecisionCapability, request: NoulRequest,
        record: @Sendable (String) -> Void
    ) async throws -> Bool {
        record("noul\n\nState:\n" + request.text + "\n\nQuestion:\n" + request.instructions)
        let session = try await model.noul(request)
        return try await session.withCleanup {
            var result: Bool?
            for try await value in session.events {
                guard result == nil else { throw CapabilityError.invalidRequest("Multiple boolean results") }
                result = value.value
            }
            guard let result else { throw CapabilityError.invalidRequest("Missing boolean result") }
            return result
        }
    }
    private func outcome(
        _ value: Bool, route: InputDecisionOutcome.Route, snapshot: InputDecisionSnapshot,
        requests: [String], modelName: String?
    ) -> InputDecisionOutcome {
        .init(route: route, modelResult: value, reason: nil, requests: requests, modelName: modelName)
    }

    private func race(
        _ key: String, until deadline: ContinuousClock.Instant, name: String? = nil,
        operation: @escaping @Sendable () async throws -> Bool
    ) async -> Attempt {
        let model = name ?? (key == "local" ? "Local Decision" : "Cloud Decision")
        let timeout = Attempt.failed("\(model) timed out", .timedOut)
        guard !stopped, !Task.isCancelled else { return .failed("Classification cancelled") }
        guard workers[key] == nil else { return .failed("\(model) is still cleaning up the previous request") }
        guard ContinuousClock.now < deadline else { return timeout }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[key] = continuation
                workers[key] = Task {
                    let result: Attempt
                    do {
                        result = .selected(try await operation())
                    } catch {
                        let reason = "\(model) failed: \(error.localizedDescription)"
                        result = .failed(reason)
                    }
                    if !Task.isCancelled {
                        self.resolve(key, result: ContinuousClock.now < deadline ? result : timeout)
                    }
                    self.workers[key] = nil
                }
                timers[key] = Task {
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    self.workers[key]?.cancel()
                    self.resolve(key, result: timeout)
                }
            }
        } onCancel: {
            Task { await self.cancel(key) }
        }
    }
    private func cancel(_ key: String) {
        workers[key]?.cancel()
        resolve(key, result: .failed("Classification cancelled"))
    }
    private func resolve(_ key: String, result: Attempt) {
        timers.removeValue(forKey: key)?.cancel()
        waiters.removeValue(forKey: key)?.resume(returning: result)
    }
}

extension InputDecisionOutcome {
    func failureIssue(for snapshot: InputDecisionSnapshot, language: String) -> ExecutionIssue? {
        guard let failure else { return nil }
        let copy = AppLanguage(preferredLanguage: language)
        return ExecutionIssue(
            id: snapshot.input.id + ".decision", title: copy.text("Decision"), source: "assistant.decision",
            message: reason ?? failure.rawValue, failureCode: "decision.classification",
            inputID: snapshot.input.id, userMessage: copy.text(failure.rawValue))
    }

    func logItem(for snapshot: InputDecisionSnapshot, duration: Duration) -> DecisionLogItem {
        let route: DecisionLogItem.Route =
            switch self.route {
            case .local, .vela, .vela31, .laya, .gemma, .apple: .local
            case .cloud: .cloud
            case .failed: .failed
            }
        return .init(
            id: snapshot.input.id, source: AgentID.assistant.rawValue, inputText: snapshot.text, duration: duration,
            route: route,
            modelResult: nil, adoptedResult: .enqueue,
            booleanResult: modelResult, signalStatus: signalStatus,
            reason: reason, requests: requests, modelName: modelName)
    }
}

/// Per-Assistant scheduling, independent of the ordinary input queue and reply cancellation.
actor AssistantDecisionQueue {
    struct Job: Sendable {
        let snapshot: InputDecisionSnapshot
        let target: UUID?
        let interrupt: @Sendable (AssistantInterrupt, String) async throws -> AssistantInterruptResult
        let complete: @Sendable (InputDecisionSnapshot, InputDecisionOutcome, Duration) async -> Void
        let updated: @Sendable () async -> Void
    }
    private var pending: [Job] = []
    private var worker: Task<Void, Never>?
    private var cancelling = false
    var count: Int { pending.count }

    func submit(_ job: Job, using model: AssistantInputDecision) throws {
        guard !cancelling else { throw CancellationError() }
        guard pending.count < 32 else { throw CommunicationError.capacityExceeded }
        pending.append(job)
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            while let job = pending.first, !Task.isCancelled {
                let started = ContinuousClock.now
                var result = await model.classify(job.snapshot)
                let duration = started.duration(to: .now)
                guard !Task.isCancelled else { return }
                guard pending.first?.snapshot.input.id == job.snapshot.input.id else { continue }
                if result.modelResult == true {
                    if let target = job.target {
                        do {
                            result.signalStatus = try await job.interrupt(
                                AssistantInterrupt(target: .reply(target)), job.snapshot.input.sessionID
                            ).rawValue
                        } catch {
                            result.signalStatus = "interrupt_failed"
                            result.reason = "Interrupt failed: \(error)"
                        }
                    } else {
                        result.signalStatus = "no_target"
                    }
                } else if result.modelResult == nil {
                    result.signalStatus = "decision_failed"
                }
                await job.complete(job.snapshot, result, duration)
                if pending.first?.snapshot.input.id == job.snapshot.input.id { pending.removeFirst() }
                await job.updated()
            }
        }
    }

    func remove(sessionID: String) {
        pending.removeAll { $0.snapshot.input.sessionID == sessionID }
    }

    func cancelAndWait() async {
        cancelling = true
        pending.removeAll()
        let active = worker
        active?.cancel()
        await active?.value
        cancelling = false
    }
}
