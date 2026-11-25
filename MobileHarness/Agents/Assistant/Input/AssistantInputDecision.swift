import AgentCore
import Foundation
import ModelKit
import ModelKitDefaults
import Synchronization
import UI

public struct InputDecisionOutcome: Sendable, Equatable {
    public enum Route: Sendable, Equatable {
        case local(modelID: String)
        case cloud, failed, superseded

        public var rawValue: String {
            switch self {
            case .local(let id): "local:" + id
            case .cloud: "cloud:decision"
            case .failed: "decision:failed"
            case .superseded: "decision:superseded"
            }
        }
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
    public var inference: InferenceMetadata? = nil
}

/// Frozen at admission: current assistant reply and latest user input.
public struct InputDecisionSnapshot: Sendable {
    public let input: AgentInput
    public let text: String
    public let currentAssistantReply: String
    public let receivedAt: ContinuousClock.Instant
    public init(
        input: AgentInput, text: String, currentAssistantReply: String = "",
        receivedAt: ContinuousClock.Instant = .now
    ) {
        self.input = input
        self.text = text
        self.currentAssistantReply = currentAssistantReply
        self.receivedAt = receivedAt
    }
    func request() throws -> NoulRequest {
        struct Context: Encodable {
            let currentAssistantReply: String
            let incomingUserInput: String
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let context = Context(currentAssistantReply: currentAssistantReply, incomingUserInput: text)
        let text = String(decoding: try encoder.encode(context), as: UTF8.self)
        return try NoulRequest(
            text: text, instructions: AgentPrompts.text("Assistant/Input/InputDecision", "question"),
            context: .init(requestID: input.id + ".decision", scopeID: input.sessionID))
    }
}

/// Root-owned bounded classification and cleanup. A timeout retires its result, not its native resource.
public actor AssistantInputDecision {
    private let localModel: @Sendable (String) async throws -> (any ModelDecisionProviding)?
    private let localChatModel: @Sendable (String) async throws -> ChatModel
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
        case superseded
    }
    private struct PendingAttempt {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let model: String
        let operation: @Sendable () async throws -> Bool
        let continuation: CheckedContinuation<Attempt, Never>
        var timeout: Attempt { .failed("\(model) timed out", .timedOut) }
    }
    private var attempts: [String: PendingAttempt] = [:]
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
        localModel: @escaping @Sendable (String) async throws -> (any ModelDecisionProviding)?,
        localChatModel: @escaping @Sendable (String) async throws -> ChatModel = { _ in
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
            do {
                if let model = try await localModel(previous), !localMaintenance.contains(previous) {
                    try await model.unload()
                }
            } catch {
                return "Could not release previous Decision model: \(error.localizedDescription)"
            }
        }
        activeLocalID = id
        localFailure = nil
        return nil
    }
    public func stop() async {
        stopped = true
        for timer in timers.values { timer.cancel() }
        for attempt in attempts.values { attempt.continuation.resume(returning: .failed("Classification cancelled")) }
        attempts.removeAll()
        let active = Array(workers.values)
        for task in active { task.cancel() }
        preparation?.cancel()
        for task in active { await task.value }
        await preparation?.value
    }
    public func classify(_ snapshot: InputDecisionSnapshot) async -> InputDecisionOutcome {
        await classify(receivedAt: snapshot.receivedAt) { try snapshot.request() }
    }

    func classify(
        receivedAt: ContinuousClock.Instant, request: @Sendable () throws -> NoulRequest
    ) async -> InputDecisionOutcome {
        await AgentPrompts.$language.withValue(AgentPrompts.normalizedLanguage(language())) {
            let evidence = Mutex<InferenceMetadata?>(nil)
            var result = await classifyInput(receivedAt: receivedAt, request: request) { metadata in
                if metadata.model != nil || metadata.startedAt != nil { evidence.withLock { $0 = metadata } }
            }
            result.inference = evidence.withLock { $0 }
            if let model = result.inference?.model { result.modelName = model.displayName ?? model.modelID }
            return result
        }
    }

    private func classifyInput(
        receivedAt: ContinuousClock.Instant, request: @Sendable () throws -> NoulRequest,
        capture: @escaping @Sendable (InferenceMetadata) -> Void
    ) async -> InputDecisionOutcome {
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
        let deadline = receivedAt.advanced(by: timeout)
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
        selectedModelName.withLock { $0 = route.localID }
        let prompt: NoulRequest
        do {
            prompt = try request()
        } catch {
            await reportFailure(.request)
            return failedOutcome("Could not prepare Decision request: \(error.localizedDescription)", failure: .request)
        }
        if let reason = await selectLocal(route.localID) {
            guard !stopped, !Task.isCancelled else { return failedOutcome("Classification cancelled") }
            await reportFailure(.model)
            return failedOutcome(reason, failure: .model)
        }
        let nativeModel: (any ModelDecisionProviding)?
        do {
            if let id = route.localID { nativeModel = try await localModel(id) } else { nativeModel = nil }
        } catch {
            await reportFailure(.model)
            return failedOutcome(error.localizedDescription, failure: .model)
        }
        let localRoute = InputDecisionOutcome.Route.local(modelID: route.localID ?? "")
        if let id = route.localID, nativeModel == nil {
            guard !localMaintenance.contains(id), activeLocalID == id else {
                await reportFailure(.unavailable)
                return failedOutcome("Local Chat model temporarily unavailable", failure: .unavailable)
            }
            let resolve = localChatModel
            let result = await race(
                "local", until: min(deadline, .now.advanced(by: localChatTimeout)),
                name: id
            ) {
                let model = try await resolve(id)
                let modelName = model.modelName ?? id
                selectedModelName.withLock { $0 = modelName }
                if case .unavailable(let reason) = await model.capability.availability {
                    throw CapabilityError.unavailable(reason)
                }
                return try await Self.read(ChatDecision(model.capability), request: prompt, capture: capture) {
                    request in
                    requests.withLock { $0.append("Local \(modelName)\n\n" + request) }
                }
            }
            switch result {
            case .superseded:
                return Self.supersededOutcome(
                    requests: requests.withLock { $0 }, modelName: selectedModelName.withLock { $0 })
            case .selected(let action):
                await report("Local \(selectedModelName.withLock { $0 } ?? id)")
                return outcome(
                    action, route: localRoute, requests: requests.withLock { $0 },
                    modelName: selectedModelName.withLock { $0 })
            case .failed(let reason, let failure):
                if !stopped, !Task.isCancelled { await reportFailure(failure) }
                return failedOutcome(reason, failure: failure)
            }
        }
        let modelName = selectedModelName.withLock { $0 } ?? "Decision"
        if let id = route.localID {
            localFailureReason = localFailure
            if switchingLocal || activeLocalID != id || localMaintenance.contains(id) {
                localFailureReason = "Decision resources are being released"
                localFailureKind = .notReady
            } else if nativeModel == nil {
                localFailureReason = "Selected local Decision model is unavailable"
                localFailureKind = .unavailable
            }
        }
        if let id = route.localID, let local = nativeModel, localFailureReason == nil, !stopped, !Task.isCancelled {
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
                        return try await Self.read(local, request: prompt, capture: capture) { request in
                            requests.withLock { $0.append("Local \(modelName)\n\n" + request) }
                        }
                    }
                    switch result {
                    case .superseded:
                        return Self.supersededOutcome(requests: requests.withLock { $0 }, modelName: modelName)
                    case .selected(let action):
                        return outcome(
                            action, route: localRoute, requests: requests.withLock { $0 },
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
            return try await Self.read(ChatDecision(model.capability), request: prompt, capture: capture) { request in
                requests.withLock { $0.append("Cloud Decision\n\n" + request) }
            }
        }
        if case .superseded = result {
            return Self.supersededOutcome(
                requests: requests.withLock { $0 }, modelName: selectedModelName.withLock { $0 })
        }
        if case .selected(let action) = result {
            return outcome(
                action, route: .cloud, requests: requests.withLock { $0 },
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
        capture: @Sendable (InferenceMetadata) -> Void, record: @Sendable (String) -> Void
    ) async throws -> Bool {
        record("noul\n\nState:\n" + request.text + "\n\nQuestion:\n" + request.instructions)
        let session = try await model.noul(request)
        capture(session.metadata)
        defer { capture(session.metadata) }
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
        _ value: Bool, route: InputDecisionOutcome.Route, requests: [String], modelName: String?
    ) -> InputDecisionOutcome {
        .init(route: route, modelResult: value, reason: nil, requests: requests, modelName: modelName)
    }

    static func supersededOutcome(requests: [String] = [], modelName: String? = nil) -> InputDecisionOutcome {
        .init(
            route: .superseded, modelResult: nil, signalStatus: "superseded",
            reason: "Decision superseded by newer input; input remains queued",
            requests: requests, modelName: modelName)
    }

    private func race(
        _ key: String, until deadline: ContinuousClock.Instant, name: String? = nil,
        operation: @escaping @Sendable () async throws -> Bool
    ) async -> Attempt {
        let model = name ?? (key == "local" ? "Local Decision" : "Cloud Decision")
        let timeout = Attempt.failed("\(model) timed out", .timedOut)
        let id = UUID()
        guard !stopped, !Task.isCancelled else { return .failed("Classification cancelled") }
        guard ContinuousClock.now < deadline else { return timeout }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !stopped, !Task.isCancelled else {
                    continuation.resume(returning: .failed("Classification cancelled"))
                    return
                }
                workers[key]?.cancel()
                resolve(key, result: .superseded)
                attempts[key] = PendingAttempt(
                    id: id, deadline: deadline, model: model, operation: operation, continuation: continuation)
                timers[key] = Task {
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    guard self.attempts[key]?.id == id else { return }
                    self.workers[key]?.cancel()
                    self.resolve(key, result: timeout)
                }
                startAttempt(key)
            }
        } onCancel: {
            Task { await self.cancel(key, attemptID: id) }
        }
    }

    private func startAttempt(_ key: String) {
        guard !stopped, workers[key] == nil, let attempt = attempts[key] else { return }
        guard ContinuousClock.now < attempt.deadline else {
            resolve(key, result: attempt.timeout)
            return
        }
        workers[key] = Task {
            let result: Attempt
            do {
                try Task.checkCancellation()
                result = .selected(try await attempt.operation())
            } catch {
                result = .failed("\(attempt.model) failed: \(error.localizedDescription)")
            }
            if self.attempts[key]?.id == attempt.id, !Task.isCancelled {
                self.resolve(key, result: ContinuousClock.now < attempt.deadline ? result : attempt.timeout)
            }
            self.workers[key] = nil
            self.startAttempt(key)
        }
    }

    private func cancel(_ key: String, attemptID: UUID? = nil) {
        if let attemptID, attempts[key]?.id != attemptID { return }
        workers[key]?.cancel()
        resolve(key, result: .failed("Classification cancelled"))
    }
    private func resolve(_ key: String, result: Attempt) {
        timers.removeValue(forKey: key)?.cancel()
        attempts.removeValue(forKey: key)?.continuation.resume(returning: result)
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
            case .local: .local
            case .cloud: .cloud
            case .failed: .failed
            case .superseded: .superseded
            }
        return .init(
            id: snapshot.input.id, source: AgentID.assistant.rawValue, inputText: snapshot.text, duration: duration,
            route: route,
            modelResult: nil, adoptedResult: .enqueue,
            booleanResult: modelResult, signalStatus: signalStatus,
            reason: reason, requests: requests, modelName: modelName, modelID: inference?.model?.modelID)
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
    private var classification: Task<InputDecisionOutcome, Never>?
    private var classifyingInputID: String?
    private var cancelling = false
    var count: Int { pending.count }

    func submit(_ job: Job, using model: AssistantInputDecision) throws {
        guard !cancelling else { throw CancellationError() }
        guard pending.count < 32 else { throw CommunicationError.capacityExceeded }
        pending.append(job)
        classification?.cancel()
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            while let job = pending.first, !Task.isCancelled {
                let started = ContinuousClock.now
                var result: InputDecisionOutcome
                if pending.count > 1 {
                    result = AssistantInputDecision.supersededOutcome()
                } else {
                    let task = Task { await model.classify(job.snapshot) }
                    classification = task
                    classifyingInputID = job.snapshot.input.id
                    result = await task.value
                    classification = nil
                    classifyingInputID = nil
                }
                let duration = started.duration(to: .now)
                guard !Task.isCancelled else { return }
                guard pending.first?.snapshot.input.id == job.snapshot.input.id else { continue }
                if pending.count > 1 {
                    let evidence = result.inference
                    result = AssistantInputDecision.supersededOutcome(
                        requests: result.requests, modelName: result.modelName)
                    result.inference = evidence
                }
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
                } else if result.modelResult == nil, result.signalStatus != "superseded" {
                    result.signalStatus = "decision_failed"
                }
                await job.complete(job.snapshot, result, duration)
                if pending.first?.snapshot.input.id == job.snapshot.input.id { pending.removeFirst() }
                await job.updated()
            }
        }
    }

    func remove(sessionID: String) {
        if pending.contains(where: {
            $0.snapshot.input.sessionID == sessionID && $0.snapshot.input.id == classifyingInputID
        }) {
            classification?.cancel()
        }
        pending.removeAll { $0.snapshot.input.sessionID == sessionID }
    }

    func cancelAndWait() async {
        cancelling = true
        pending.removeAll()
        let active = worker
        active?.cancel()
        classification?.cancel()
        await active?.value
        cancelling = false
    }
}
