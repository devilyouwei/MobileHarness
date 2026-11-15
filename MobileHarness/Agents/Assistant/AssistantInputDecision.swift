import AgentCore
import Foundation
import ModelKit
import ModelKitDefaults
import Synchronization
import UI

public enum InputDisposition: String, Codable, Sendable {
    case enqueue, discard, interrupt
    case continueListening = "continue_listening"

    static let standardChoices: [Self] = [.interrupt, .discard, .enqueue]
}

public struct InputDecisionOutcome: Sendable, Equatable {
    public enum Route: String, Sendable {
        case local = "local:d3-edge"
        case lite = "local:d3-lite"
        case gemma = "local:gemma4-e2b"
        case apple = "local:apple-system"
        case cloud = "cloud:decision"
        case fallback = "enqueue:fallback"
    }
    public let route: Route
    public let modelResult: InputDisposition?
    public let adopted: InputDisposition
    public let reason: String?
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
}

/// One pending input, one earlier exchange and a bounded excerpt of the same-session buffer.
public struct InputDecisionSnapshot: Sendable {
    public struct Exchange: Sendable, Equatable {
        public let user: String
        public let assistant: String

        public init(user: String, assistant: String) {
            self.user = String(user.suffix(80))
            self.assistant = String(assistant.suffix(80))
        }
    }

    public let input: AgentInput
    public let text: String
    public let running: Bool
    public let playing: Bool?
    public let history: Exchange?
    public let bufferedUserInputs: [String]
    public let question: String?
    public let allowsContinueListening: Bool
    let canHoldTranscript: Bool
    public var occupied: Bool { running || playing == true }
    public var protectsAnswer: Bool { question != nil }
    public let receivedAt: ContinuousClock.Instant
    public init(
        input: AgentInput, text: String, running: Bool, playing: Bool? = nil, history: Exchange? = nil,
        bufferedUserInputs: [String] = [], question: String? = nil,
        receivedAt: ContinuousClock.Instant = .now, allowsContinueListening: Bool = false,
        canHoldTranscript: Bool = true
    ) {
        self.input = input
        self.text = text
        self.running = running
        self.playing = playing
        self.history = history
        self.bufferedUserInputs = bufferedUserInputs.suffix(3).map { String($0.suffix(80)) }
        self.question = question.map { String($0.suffix(80)) }
        self.receivedAt = receivedAt
        self.allowsContinueListening = allowsContinueListening
        self.canHoldTranscript = canHoldTranscript
    }

    struct Prompt: Sendable {
        let background: String
        let latest: String
        let context: InferenceContext
        let choices: [InputDisposition]
        var labels: [String] { choices.indices.map { String($0 + 1) } }

        var text: String { background + "\n\n" + latest }
    }

    func prompt() throws -> Prompt {
        let owner = "Assistant/InputDecision"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func quote(_ text: String) throws -> String {
            String(decoding: try encoder.encode(text), as: UTF8.self)
                .replacingOccurrences(of: "<", with: "\\u003c")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        let empty = try AgentPrompts.text(owner, "empty")
        let historyText =
            try history.map {
                try AgentPrompts.text(owner, "history", ["user": quote($0.user), "assistant": quote($0.assistant)])
            } ?? empty
        let buffer = try bufferedUserInputs.map(quote).joined(separator: "\n")
        var definitions = try AgentPrompts.text(owner, "definitions")
        var choices = InputDisposition.standardChoices
        if allowsContinueListening {
            definitions += "\n" + (try AgentPrompts.text(owner, "continueDefinition"))
            choices.append(.continueListening)
        }
        let state = try AgentPrompts.text(
            owner, "state",
            [
                "running": AgentPrompts.text(owner, running ? "yes" : "no"),
                "playing": AgentPrompts.text(owner, playing.map { $0 ? "yes" : "no" } ?? "unknown"),
                "question": question.map(quote) ?? empty,
            ])
        let context = try AgentPrompts.text(
            owner, "context", ["history": historyText, "buffer": buffer.isEmpty ? empty : buffer])
        let latest = try AgentPrompts.text(
            owner, allowsContinueListening ? "latestSpeech" : "latest",
            [
                "input": quote(text)
            ])
        return .init(
            background: definitions + "\n\n" + state + "\n\n" + context, latest: latest,
            context: .init(requestID: input.id + ".decision", scopeID: input.sessionID), choices: choices)
    }
}

/// Root-owned bounded classification and cleanup. A timeout retires its result, not its native resource.
public actor AssistantInputDecision {
    private enum TranscriptContent {
        case possibleSpeech, filler, noise
    }

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
        case selected(InputDisposition)
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
            local: local, configuration: configuration, timeout: .seconds(2), localTimeout: .milliseconds(250),
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
        timeout: Duration = .seconds(2), localTimeout: Duration = .milliseconds(250),
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
        var localFailureReason: String?
        var localFailureKind: InputDecisionOutcome.Failure = .model
        func fallback(_ reason: String, failure: InputDecisionOutcome.Failure? = nil) -> InputDecisionOutcome {
            .init(
                route: .fallback, modelResult: nil,
                adopted: snapshot.allowsContinueListening && Self.transcriptContent(snapshot) == .noise
                    ? .discard : .enqueue, reason: reason,
                requests: requests.withLock { $0 }, failure: failure)
        }
        guard !stopped, !Task.isCancelled else { return fallback("Classification cancelled") }
        let deadline = snapshot.receivedAt.advanced(by: timeout)
        guard ContinuousClock.now < deadline else { return fallback("Classification timed out", failure: .timedOut) }
        let route: SelectedConfiguration
        do { route = try await configuration() } catch {
            guard !stopped, !Task.isCancelled, !(error is CancellationError) else {
                return fallback("Classification cancelled")
            }
            await reportFailure(.settings)
            return fallback("Could not read Decision settings: \(error.localizedDescription)", failure: .settings)
        }
        let prompt: InputDecisionSnapshot.Prompt
        do {
            prompt = try snapshot.prompt()
        } catch {
            await reportFailure(.request)
            return fallback("Could not prepare Decision request: \(error.localizedDescription)", failure: .request)
        }
        if let reason = await selectLocal(route.localID) {
            guard !stopped, !Task.isCancelled else { return fallback("Classification cancelled") }
            await reportFailure(.model)
            return fallback(reason, failure: .model)
        }
        if let id = route.localID, id == "gemma4-e2b" || id == "apple-system" {
            let modelName = id == "apple-system" ? "Apple System LLM" : "Gemma 4 E2B"
            let modelRoute: InputDecisionOutcome.Route = id == "apple-system" ? .apple : .gemma
            guard !localMaintenance.contains(id), activeLocalID == id else {
                await reportFailure(.unavailable)
                return fallback("Local Chat model temporarily unavailable", failure: .unavailable)
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
                return try await AssistantDecisionProtocol.chat(model, modelID: id).classify(prompt) { request in
                    requests.withLock { $0.append("Local \(modelName)\n\n" + request) }
                }
            }
            switch result {
            case .selected(let action):
                await report("Local \(modelName)")
                return outcome(action, route: modelRoute, snapshot: snapshot, requests: requests.withLock { $0 })
            case .failed(let reason, let failure):
                if !stopped, !Task.isCancelled { await reportFailure(failure) }
                return fallback(reason, failure: failure)
            }
        }
        let modelName = route.localID == "d3-lite" ? "D3 Lite" : "D3"
        let modelRoute: InputDecisionOutcome.Route = route.localID == "d3-lite" ? .lite : .local
        if let id = route.localID {
            localFailureReason = localFailure
            if switchingLocal || activeLocalID != id || localMaintenance.contains(id) {
                localFailureReason = "D3 resources are being released"
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
                    localFailureReason = "D3 resources are being released"
                    localFailureKind = .notReady
                } else if status == .ready {
                    await report(AppLanguage(preferredLanguage: language()).format("Local · %@", modelName))
                    let result = await race("local", until: min(deadline, .now.advanced(by: localTimeout))) {
                        try Task.checkCancellation()
                        return try await AssistantDecisionProtocol.jev(local).classify(prompt) { request in
                            requests.withLock { $0.append("Local \(modelName)\n\n" + request) }
                        }
                    }
                    switch result {
                    case .selected(let action):
                        return outcome(
                            action, route: modelRoute, snapshot: snapshot, requests: requests.withLock { $0 })
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
                                self.localFailure = "D3 preparation failed: \(error.localizedDescription)"
                                await self.reportFailure(.model)
                            } catch {}
                            self.preparation = nil
                        }
                    }
                }
            } catch {
                localFailureReason = "Could not read D3 status: \(error.localizedDescription)"
            }
        }
        guard !stopped, !Task.isCancelled else { return fallback("Classification cancelled") }
        if route.localID != nil {
            let reason = localFailureReason ?? "Selected local Decision model is unavailable"
            await reportFailure(localFailureKind)
            return fallback(reason, failure: localFailureKind)
        }
        guard ContinuousClock.now < deadline else {
            await reportFailure(.timedOut)
            return fallback("Classification timed out", failure: .timedOut)
        }
        guard let cloud = route.cloud else {
            await reportFailure(.unavailable)
            return fallback("Cloud Decision is unconfigured", failure: .unavailable)
        }
        await report(AppLanguage(preferredLanguage: language()).text("Cloud · Selected Decision model"))
        let result = await race("cloud", until: deadline) {
            let model = try await cloud()
            return try await AssistantDecisionProtocol.chat(model.capability, modelID: model.modelName)
                .classify(prompt) { request in
                    requests.withLock { $0.append("Cloud Decision\n\n" + request) }
                }
        }
        if case .selected(let action) = result {
            return outcome(
                action, route: .cloud, snapshot: snapshot, requests: requests.withLock { $0 })
        }
        if stopped || Task.isCancelled { return fallback("Classification cancelled") }
        if case .failed(let reason, let failure) = result {
            await reportFailure(failure)
            return fallback(reason, failure: failure)
        }
        return fallback("Model returned no valid classification", failure: .model)
    }

    private func reportFailure(_ failure: InputDecisionOutcome.Failure) async {
        await report(AppLanguage(preferredLanguage: language()).text(failure.rawValue))
    }

    private func outcome(
        _ action: InputDisposition, route: InputDecisionOutcome.Route, snapshot: InputDecisionSnapshot,
        requests: [String]
    ) -> InputDecisionOutcome {
        let content = Self.transcriptContent(snapshot)
        let adopted: InputDisposition
        let reason: String?
        switch (action, content) {
        case (_, .noise):
            adopted = .discard
            reason = action == .discard ? nil : "Transcript contains only noise markers or has no usable text"
        case (.discard, .possibleSpeech):
            adopted = .enqueue
            reason =
                snapshot.protectsAnswer
                ? "Retained a valid answer to the current interaction" : "Retained potentially useful input"
        case (.interrupt, _) where !snapshot.occupied:
            adopted = .enqueue
            reason = "No active reply to interrupt"
        case (.continueListening, _) where !snapshot.canHoldTranscript:
            adopted = .discard
            reason = "Continuation buffer reached its limit"
        default:
            adopted = action
            reason = nil
        }
        return .init(
            route: route, modelResult: action, adopted: adopted, reason: reason,
            requests: requests)
    }

    private static func transcriptContent(_ snapshot: InputDecisionSnapshot) -> TranscriptContent {
        guard !snapshot.protectsAnswer,
            case .transcript(let transcript, final: true)? = snapshot.input.payload.perception
        else { return .possibleSpeech }
        let latest = snapshot.allowsContinueListening ? transcript : snapshot.text
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noiseMarkers: Set<String> = [
            "[noise]", "[background noise]", "[inaudible]", "[unintelligible]", "[music]", "[silence]",
            "[杂音]", "[噪声]", "[噪音]", "[听不清]", "[音乐]", "（杂音）", "（噪声）", "（听不清）",
        ]
        let marker = text.trimmingCharacters(in: CharacterSet(charactersIn: ".。!！…"))
        if noiseMarkers.contains(marker) { return .noise }

        func hasQuestionMark(_ value: String) -> Bool { value.contains("?") || value.contains("？") }
        guard !hasQuestionMark(text) else { return .possibleSpeech }
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "�"))
        let words = text.components(separatedBy: separators).filter { !$0.isEmpty }
        if words.isEmpty { return .noise }
        guard !hasQuestionMark(snapshot.history?.assistant ?? "") else { return .possibleSpeech }

        let englishFillers: Set<String> = ["ah", "eh", "er", "hm", "hmm", "mm", "mmm", "oh", "uh", "um", "umm"]
        let isFiller = words.allSatisfy { word in
            englishFillers.contains(word) || word.allSatisfy { "嗯啊呃唔哦唉欸哎".contains($0) }
        }
        return isFiller ? .filler : .possibleSpeech
    }

    private func race(
        _ key: String, until deadline: ContinuousClock.Instant, name: String? = nil,
        operation: @escaping @Sendable () async throws -> InputDisposition
    ) async -> Attempt {
        let model = name ?? (key == "local" ? "D3" : "Cloud Decision")
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
            case .local, .lite, .gemma, .apple: .local
            case .cloud: .cloud
            case .fallback: .fallback
            }
        return .init(
            id: snapshot.input.id, source: AgentID.assistant.rawValue, inputText: snapshot.text, duration: duration,
            route: route,
            modelResult: modelResult.map(\.logDisposition), adoptedResult: adopted.logDisposition,
            reason: reason, requests: requests)
    }
}

extension InputDisposition {
    fileprivate var logDisposition: DecisionLogItem.Disposition {
        switch self {
        case .enqueue: .enqueue
        case .discard: .discard
        case .interrupt: .interrupt
        case .continueListening: .continueListening
        }
    }
}
