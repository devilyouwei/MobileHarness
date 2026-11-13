import AgentCore
import Foundation
import ModelKit
import ModelKitDefaults
import Synchronization

public enum InputDisposition: String, Codable, Sendable { case enqueue, discard, interrupt }

public struct InputDecisionOutcome: Sendable, Equatable {
    public enum Route: String, Sendable {
        case local = "local:d3-edge"
        case cloud = "cloud:decision"
        case fallback = "enqueue:fallback"
    }
    public let route: Route
    public let modelResult: InputDisposition?
    public let adopted: InputDisposition
    public let reason: String?
    public let requests: [String]
    public let localFallback: String?
}

/// One pending input and at most one earlier user/assistant exchange from the current dialog.
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
    public let question: String?
    public var occupied: Bool { running || playing == true }
    public var protectsAnswer: Bool { question != nil }
    public let receivedAt: ContinuousClock.Instant
    public init(
        input: AgentInput, text: String, running: Bool, playing: Bool? = nil, history: Exchange? = nil,
        question: String? = nil,
        receivedAt: ContinuousClock.Instant = .now
    ) {
        self.input = input
        self.text = text
        self.running = running
        self.playing = playing
        self.history = history
        self.question = question.map { String($0.suffix(80)) }
        self.receivedAt = receivedAt
    }

    func request() throws -> DecisionRequest {
        let owner = "Assistant/InputDecision"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func quote(_ text: String) throws -> String {
            String(decoding: try encoder.encode(text), as: UTF8.self)
                .replacingOccurrences(of: "<", with: "\\u003c")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        let historyText =
            try history.map {
                try AgentPrompts.text(owner, "history", ["user": quote($0.user), "assistant": quote($0.assistant)])
            } ?? ""
        let questionText = try question.map { try AgentPrompts.text(owner, "question", ["question": quote($0)]) } ?? ""
        return try DecisionRequest(
            text: AgentPrompts.text(
                owner, "input",
                [
                    "playing": playing.map { $0 ? "yes" : "no" } ?? "unknown",
                    "running": running ? "yes" : "no", "awaitingAnswer": protectsAnswer ? "yes" : "unknown",
                    "history": historyText, "question": questionText, "input": quote(text),
                ]),
            candidates: [InputDisposition.interrupt, .discard, .enqueue].map { action in
                try "\(action.rawValue): \(AgentPrompts.text(owner, action.rawValue))"
            },
            context: .init(requestID: input.id + ".decision", scopeID: input.sessionID),
            instructions: AgentPrompts.text(owner, "instructions"))
    }
}

/// Root-owned bounded classification and cleanup. A timeout retires its result, not its native resource.
public actor AssistantInputDecision {
    private enum TranscriptContent {
        case possibleSpeech, filler, noise
    }

    private let local: any ModelDecisionProviding
    public typealias Configuration = (useLocal: Bool, cloud: (@Sendable () async throws -> any ChatCapability)?)
    private let configuration: @Sendable () async throws -> Configuration
    private let report: @Sendable (String) async -> Void
    private let timeout: Duration
    private let localTimeout: Duration
    private var workers: [String: Task<Void, Never>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private enum Attempt: Sendable {
        case selected(InputDisposition)
        case failed(String)
    }
    private var waiters: [String: CheckedContinuation<Attempt, Never>] = [:]
    private var localFailure: String?
    private var preparation: Task<Void, Never>?
    private var stopped = false
    public init(
        local: any ModelDecisionProviding,
        selection: @escaping @Sendable () async throws -> Bool,
        cloud: @escaping @Sendable () async throws -> any ChatCapability,
        report: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.init(local: local, configuration: { (try await selection(), cloud) }, report: report)
    }
    public init(
        local: any ModelDecisionProviding,
        configuration: @escaping @Sendable () async throws -> Configuration,
        report: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.init(
            local: local, configuration: configuration, timeout: .seconds(2), localTimeout: .milliseconds(250),
            report: report)
    }

    init(
        local: any ModelDecisionProviding,
        configuration: @escaping @Sendable () async throws -> Configuration,
        timeout: Duration, localTimeout: Duration,
        report: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.local = local
        self.configuration = configuration
        self.report = report
        self.timeout = timeout
        self.localTimeout = localTimeout
    }
    public func resetLocalFailure() { localFailure = nil }
    public func quiesceLocal() async {
        localFailure = "D3 资源正在释放"
        preparation?.cancel()
        cancel("local")
        await preparation?.value
        await workers["local"]?.value
        do { try await local.unload() } catch { await report("D3 资源释放失败：\(error)") }
    }
    public func stop() async {
        stopped = true
        for timer in timers.values { timer.cancel() }
        for waiter in waiters.values { waiter.resume(returning: .failed("分类已取消")) }
        waiters.removeAll()
        let active = Array(workers.values)
        for task in active { task.cancel() }
        preparation?.cancel()
        for task in active { await task.value }
        await preparation?.value
    }
    public func classify(_ snapshot: InputDecisionSnapshot) async -> InputDecisionOutcome {
        let requests = Mutex<[String]>([])
        var localFallback: String?
        func fallback(_ reason: String) -> InputDecisionOutcome {
            .init(
                route: .fallback, modelResult: nil, adopted: .enqueue, reason: reason,
                requests: requests.withLock { $0 }, localFallback: localFallback)
        }
        guard !stopped, !Task.isCancelled else { return fallback("分类已取消") }
        let deadline = snapshot.receivedAt.advanced(by: timeout)
        guard ContinuousClock.now < deadline else { return fallback("分类超时") }
        let route: Configuration
        do { route = try await configuration() } catch {
            await report("分类偏好读取失败，保留输入并排队：\(error)")
            return fallback("分类配置读取失败")
        }
        let request: DecisionRequest
        do {
            request = try snapshot.request()
        } catch {
            await report("分类请求准备失败，保留输入并排队：\(error)")
            return fallback("分类请求准备失败")
        }
        if route.useLocal {
            localFallback = localFailure
        } else {
            localFallback = "当前配置使用云端 Decision"
        }
        if route.useLocal, localFailure == nil {
            do {
                let status = try await local.status()
                if status == .ready {
                    await report("本地 D3")
                    let local = local
                    let result = await race("local", until: min(deadline, .now.advanced(by: localTimeout))) {
                        try Task.checkCancellation()
                        requests.withLock {
                            $0.append(
                                "本地 D3\n\nInstructions\n" + request.instructions
                                    + "\n\nCandidates\n" + request.candidates.joined(separator: "\n")
                                    + "\n\nInput\n" + request.text)
                        }
                        let session = try await local.decide(request)
                        return try await withTaskCancellationHandler {
                            var result: InputDisposition?
                            do {
                                for try await value in session.events {
                                    guard result == nil, case .selected(let label, _) = value.decision,
                                        let id = label.split(separator: ":", maxSplits: 1).first,
                                        request.candidates.contains(label),
                                        let action = InputDisposition(rawValue: String(id))
                                    else {
                                        throw CapabilityError.invalidRequest("Invalid Decision result")
                                    }
                                    result = action
                                }
                                await session.waitForCompletion()
                                return result
                            } catch {
                                session.cancel()
                                await session.waitForCompletion()
                                throw error
                            }
                        } onCancel: {
                            session.cancel()
                        }
                    }
                    switch result {
                    case .selected(let action):
                        return outcome(action, route: .local, snapshot: snapshot, requests: requests.withLock { $0 })
                    case .failed(let reason):
                        localFallback = reason
                    }
                } else {
                    localFallback = "D3 尚未就绪（\(status.rawValue)）"
                    if preparation == nil {
                        let local = local
                        preparation = Task {
                            do { try await local.warmup() } catch
                                where !Task.isCancelled && !(error is CancellationError)
                            {
                                self.localFailure = "D3 准备失败：\(error.localizedDescription)"
                                await self.report("D3 准备失败，暂用云端：\(error)")
                            } catch {}
                            self.preparation = nil
                        }
                    }
                }
            } catch {
                localFallback = "D3 状态读取失败：\(error.localizedDescription)"
                await report("D3 不可用，暂用云端：\(error)")
            }
        }
        guard !stopped, !Task.isCancelled else { return fallback("分类已取消") }
        guard ContinuousClock.now < deadline else {
            await report("分类超时，保留输入并排队")
            return fallback("分类超时")
        }
        guard let cloud = route.cloud else {
            await report("Decision 云端未配置，保留输入并排队")
            return fallback("Decision 云端未配置")
        }
        await report(route.useLocal ? "暂用云端 · Decision 独立配置" : "云端 · Decision 独立配置")
        let result = await race("cloud", until: deadline) {
            let model = try await cloud()
            guard await model.supportsToolCalls else {
                throw CapabilityError.unavailable("Cloud model does not support tools")
            }
            let declaration = try JSONSerialization.data(withJSONObject: [
                "type": "function",
                "function": [
                    "name": "classify_input",
                    "description": try AgentPrompts.text("Assistant/InputDecision", "toolDescription"),
                    "parameters": [
                        "type": "object",
                        "properties": ["action": ["type": "string", "enum": ["enqueue", "discard", "interrupt"]]],
                        "required": ["action"], "additionalProperties": false,
                    ],
                ],
            ])
            let chat = try ChatRequest(
                messages: [
                    .init(
                        role: .system, content: ([request.instructions] + request.candidates).joined(separator: "\n")),
                    .init(role: .user, content: request.text),
                ],
                context: request.context, maximumOutputTokens: 128, temperature: 0,
                tools: [ChatToolDefinition(declaration: declaration)],
                toolChoice: .required(name: "classify_input"))
            try Task.checkCancellation()
            let messages = chat.messages.map { $0.role.rawValue + "\n" + $0.content }
            let tools = chat.tools.map { "Tool\n" + String(decoding: $0.declaration, as: UTF8.self) }
            let tokenLimit = chat.maximumOutputTokens.map(String.init) ?? "default"
            requests.withLock {
                $0.append(
                    (["云端 Decision"] + messages + tools + [
                        "tool_choice: \(chat.toolChoice)",
                        "maximum_output_tokens: \(tokenLimit)\ntemperature: \(chat.temperature)",
                    ]).joined(separator: "\n\n"))
            }
            let session = try await model.chat(chat)
            return try await withTaskCancellationHandler {
                do {
                    var action: InputDisposition?
                    for try await event in session.events {
                        switch event {
                        case .text(let value):
                            guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                throw CapabilityError.invalidRequest("Decision returned text instead of a tool")
                            }
                        case .toolCall(let call):
                            guard action == nil, call.name == "classify_input",
                                let object = try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))
                                    as? [String: String],
                                Set(object.keys) == ["action"], let raw = object["action"],
                                let valid = InputDisposition(rawValue: raw)
                            else { throw CapabilityError.invalidRequest("Invalid classification tool call") }
                            action = valid
                        case .finished(let reason):
                            guard reason != .lengthLimit else {
                                throw CapabilityError.invalidRequest("Truncated decision")
                            }
                        case .usage: break
                        }
                    }
                    await session.waitForCompletion()
                    guard let action else { throw CapabilityError.invalidRequest("Missing classification tool call") }
                    return action
                } catch {
                    session.cancel()
                    await session.waitForCompletion()
                    throw error
                }
            } onCancel: {
                session.cancel()
            }
        }
        if case .selected(let action) = result {
            return outcome(
                action, route: .cloud, snapshot: snapshot, requests: requests.withLock { $0 },
                localFallback: localFallback)
        }
        await report("分类不可用，保留输入并排队")
        if stopped || Task.isCancelled { return fallback("分类已取消") }
        return fallback(ContinuousClock.now >= deadline ? "分类超时" : "模型未返回有效分类")
    }

    private func outcome(
        _ action: InputDisposition, route: InputDecisionOutcome.Route, snapshot: InputDecisionSnapshot,
        requests: [String], localFallback: String? = nil
    ) -> InputDecisionOutcome {
        let content = Self.transcriptContent(snapshot)
        let adopted: InputDisposition
        let reason: String?
        switch (action, content) {
        case (_, .noise):
            adopted = .discard
            reason = action == .discard ? nil : "语音转写只有噪声标记或无正文字符"
        case (.discard, .possibleSpeech):
            adopted = .enqueue
            reason = snapshot.protectsAnswer ? "保留当前交互的有效答复" : "保留可能有效的用户输入"
        case (.interrupt, _) where !snapshot.occupied:
            adopted = .enqueue
            reason = "当前没有需要打断的回复"
        default:
            adopted = action
            reason = nil
        }
        return .init(
            route: route, modelResult: action, adopted: adopted, reason: reason,
            requests: requests, localFallback: localFallback)
    }

    private static func transcriptContent(_ snapshot: InputDecisionSnapshot) -> TranscriptContent {
        guard !snapshot.protectsAnswer, case .transcript(_, final: true)? = snapshot.input.payload.perception
        else { return .possibleSpeech }
        let text = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        _ key: String, until deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> InputDisposition?
    ) async -> Attempt {
        let model = key == "local" ? "D3" : "云端 Decision"
        let timeout = Attempt.failed("\(model) 超时")
        guard !stopped, !Task.isCancelled else { return .failed("分类已取消") }
        guard workers[key] == nil else { return .failed("\(model) 上次请求仍在清理") }
        guard ContinuousClock.now < deadline else { return timeout }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[key] = continuation
                workers[key] = Task {
                    let result: Attempt
                    do {
                        result = try await operation().map(Attempt.selected) ?? .failed("\(model) 未返回有效分类")
                    } catch {
                        let reason = "\(model) 失败：\(error.localizedDescription)"
                        result = .failed(reason)
                        if !Task.isCancelled, !(error is CancellationError), ContinuousClock.now < deadline {
                            // Request failures can fall back without disabling the model for later inputs.
                            await self.report(reason)
                        }
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
        resolve(key, result: .failed("分类已取消"))
    }
    private func resolve(_ key: String, result: Attempt) {
        timers.removeValue(forKey: key)?.cancel()
        waiters.removeValue(forKey: key)?.resume(returning: result)
    }
}
