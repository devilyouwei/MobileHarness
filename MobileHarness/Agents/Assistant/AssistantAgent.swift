import AgentCore
import Foundation
import ModelKit

/// Model-backed assistant; concrete model selection belongs exclusively to the composition root.
public actor AssistantAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    private let textActions: [String]
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private var port: AgentMessaging?
    public func bind(_ port: AgentMessaging) throws {
        guard lifecycle == .registered, self.port == nil else { throw HarnessError.invalidTransition }
        self.port = port
    }
    private var lifecycle: AgentLifecycle = .registered
    private var queue: [AgentInput] = []
    private var processed = 0
    private let capacity: Int
    private let chat: any ChatCapability
    private var worker: Task<Void, Never>?
    private var activeInput: AgentInput?
    private var historySession: UUID?
    private var begunSession: UUID?
    private var begunTurn: ConversationTurn?
    private var outputSequence: UInt64 = 0
    private var history: [ChatMessage] = []

    public init(
        capacity: Int = 32, chat: any ChatCapability,
        configuration: AgentConfiguration? = nil
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "Assistant")
        guard configuration.agentID == .assistant else { throw AgentConfigurationError.identityMismatch }
        guard !configuration.textActions.isEmpty else { throw AgentConfigurationError.invalidField("textActions") }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Assistant", inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.actionCall, .toolCall, .control, .scheduling], capabilities: configuration.capabilities)
        textActions = configuration.textActions
        precondition(capacity > 0)
        self.capacity = capacity
        self.chat = chat
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(256))
        outputs = stream.stream
        continuation = stream.continuation
    }
    /// Shared with explicit model diagnostics; capability declarations remain in Assistant JSON.
    public nonisolated static func systemPrompt(capabilities: CapabilityRegistry) -> String {
        "你是手机上的语音助手。直接、简洁地回答，通常不超过三句话。使用用户的语言回复，当前语音支持中文和英语。每句尽量简短，只输出可朗读的纯文本和已声明的行为标签，不使用 Markdown 或 emoji；英语中的小数和金额用英文单词表达。不输出思考过程。不要声称已执行未执行的操作。\n"
            + CapabilityContextBuilder.build(capabilities)
    }

    public func start() throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        lifecycle = .running
    }
    public func pause() throws {
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        lifecycle = .paused
    }
    public func resume() throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        lifecycle = .running
        drain()
    }
    public func stop() async {
        lifecycle = .stopped
        queue.removeAll()
        history.removeAll()
        worker?.cancel()
        await worker?.value
        continuation.finish()
    }
    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: queue.count, processedInputs: processed)
    }
    public func receive(_ input: AgentInput) async throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard descriptor.inputs.contains(input.payload.kind) else { throw HarnessError.unsupportedInput }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        if case .observation(let observation) = input.payload {
            switch observation {
            case .transcript(_, final: true), .speechPhase: break
            default: throw HarnessError.unsupportedInput
            }
            _ = try observation.validatedSize()
        }
        // Control admission bypasses the ordinary queue, including when it is full or paused.
        if case .event("assistant.cancel") = input.payload {
            queue.removeAll { $0.sessionID == input.sessionID }
            if historySession == input.sessionID {
                history.removeAll()
                historySession = nil
            }
            if activeInput?.sessionID == input.sessionID {
                let task = worker
                task?.cancel()
                await task?.value
            }
            return
        }
        guard queue.count < capacity else { throw HarnessError.queueFull }
        if case .text(let text) = input.payload {
            guard text.utf8.count <= 4096 else { throw CapabilityError.invalidRequest("Assistant input exceeds 4 KiB") }
        }
        queue.append(input)
        if lifecycle == .running { drain() }
    }
    private func drain() {
        guard worker == nil else { return }
        while lifecycle == .running && !queue.isEmpty {
            let input = queue.removeFirst()
            if input.metadata.expired { continue }
            processed += 1
            switch input.payload {
            case .text(let text), .observation(.transcript(let text, final: true)):
                if text == "/status" {
                    do {
                        emit(
                            .toolCall(try descriptor.capabilities.resolveTool("runtimeInfo", arguments: [:])),
                            for: input)
                    } catch { emit(.control("assistant.error: \(error)"), for: input) }
                } else {
                    activeInput = input
                    worker = Task { await self.generate(text, input: input, using: chat) }
                    return
                }
            case .observation(.speechPhase(.speaking)):
                do {
                    try beginReplyTurn(input)
                    emit(.control("agent.finished"), for: input)
                } catch { emit(.control("assistant.error: \(error)"), for: input) }
            case .image, .audio, .observation: break  // Rejected by the descriptor before admission.
            case .event(let event):
                activeInput = input
                worker = Task { await self.emitImmediate("事件：\(event)", for: input) }
                return
            case .toolResult(let result):
                activeInput = input
                worker = Task { await self.emitImmediate(result.value, for: input) }
                return
            }
        }
    }
    private func beginReplyTurn(_ input: AgentInput) throws {
        guard let turn = input.turn else { return }
        if begunSession == input.sessionID, let begunTurn, turn.ordinal <= begunTurn.ordinal { return }
        if begunTurn == turn { return }
        let call = try descriptor.capabilities.resolveAction("beginReplyTurn", parameters: [:])
        guard emit(.actionCall(call), for: input) else { throw HarnessError.queueFull }
        begunSession = input.sessionID
        begunTurn = turn
    }
    private func generate(_ text: String, input: AgentInput, using chat: any ChatCapability) async {
        defer {
            activeInput = nil
            worker = nil
            drain()
        }
        do {
            try beginReplyTurn(input)
            if historySession != input.sessionID {
                history.removeAll()
                historySession = input.sessionID
            }
            let messages =
                [
                    ChatMessage(
                        role: .system,
                        content: Self.systemPrompt(capabilities: descriptor.capabilities))
                ]
                + history + [.init(role: .user, content: text)]
            let request = try ChatRequest(
                messages: messages,
                context: InferenceContext(requestID: input.id, conversationID: input.sessionID),
                maximumOutputTokens: 256, temperature: 0.7)
            let reply = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await self.collect(request, input: input, using: chat) }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw CapabilityError.unavailable("Assistant generation timed out")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? ""
            }
            try Task.checkCancellation()
            guard lifecycle == .running || lifecycle == .paused else { return }
            history += [.init(role: .user, content: text), .init(role: .assistant, content: reply)]
            while history.count > 8 || history.reduce(0, { $0 + $1.content.count }) > 1600 {
                history.removeFirst(min(2, history.count))
            }
            emit(.control("assistant.finished"), for: input)
        } catch is CancellationError {} catch {
            guard !Task.isCancelled, lifecycle == .running || lifecycle == .paused else { return }
            emit(.control("assistant.error: \(error)"), for: input)
        }
    }
    private func collect(_ request: ChatRequest, input: AgentInput, using chat: any ChatCapability) async throws
        -> String
    {
        let session = try await chat.chat(request)
        defer { session.cancel() }
        return try await withTaskCancellationHandler {
            var text = ""
            var finished = false
            var generator = try AgentGenerator(capabilities: descriptor.capabilities, textActions: textActions)
            var emittedCalls = 0
            for try await event in session.events {
                try Task.checkCancellation()
                guard !finished else { throw CapabilityError.invalidRequest("Events after chat completion") }
                switch event {
                case .text(let delta):
                    guard text.utf8.count + delta.utf8.count <= 2000 else { throw CapabilityError.eventTooLarge }
                    text += delta
                    try await emitFunctions(generator.append(delta), for: input, count: &emittedCalls)
                case .finished: finished = true
                }
            }
            guard finished, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CapabilityError.unavailable("LLM returned no completed answer")
            }
            try await emitFunctions(generator.finish(), for: input, count: &emittedCalls)
            guard emittedCalls > 0 else { throw CapabilityError.unavailable("LLM returned no speakable answer") }
            return text
        } onCancel: {
            session.cancel()
        }
    }
    private func emitImmediate(_ text: String, for input: AgentInput) async {
        defer {
            worker = nil
            activeInput = nil
            drain()
        }
        do {
            guard text.utf8.count <= 2000 else { throw CapabilityError.eventTooLarge }
            var generator = try AgentGenerator(capabilities: descriptor.capabilities, textActions: textActions)
            var count = 0
            try await emitFunctions(
                generator.append(AgentGenerator.escapeText(text)) + generator.finish(), for: input, count: &count)
            emit(.control("assistant.finished"), for: input)
        } catch {
            emit(.control("assistant.error: \(error)"), for: input)
        }
    }
    private func emitFunctions(_ calls: [GenerationEvent], for input: AgentInput, count: inout Int) async throws {
        for event in calls {
            if case .scheduling(let directive) = event {
                try Task.checkCancellation()
                guard emit(.scheduling(directive), for: input) else { throw HarnessError.queueFull }
                continue
            }
            guard case .action(let original) = event else { continue }
            var call = original
            try Task.checkCancellation()
            guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
            guard count < 120 else { throw GenerationError.limitExceeded }
            count += 1
            if call.actionPath == ActionPath(module: "Speech", function: "speak"), let text = call.parameters["text"] {
                guard let port else { throw CommunicationError.scopeClosed }
                let request = try SpeechSynthesisInput(text: text)
                let target = AgentID(rawValue: "speechSynthesis")
                let report = try await port.send(.speechSynthesis(request), parent: input, to: target)
                guard report.delivered.contains(target), report.rejected.isEmpty else {
                    throw CommunicationError.unavailableTarget
                }
                do {
                    try Task.checkCancellation()
                    call = try descriptor.capabilities.resolveAction(
                        "playAudio", parameters: ["audioID": request.audioID.uuidString], channel: original.channel)
                    guard emit(.actionCall(call), for: input) else { throw HarnessError.queueFull }
                } catch {
                    // Explicit command admission has its own deadline and preserves the owning input ID.
                    let cleanup = input
                    let cleanupTask = Task.detached {
                        try await port.send(.cancelSpeech(request.audioID), parent: cleanup, to: target)
                    }
                    _ = try? await cleanupTask.value
                    throw error
                }
                continue
            }
            guard emit(.actionCall(call), for: input) else { throw HarnessError.queueFull }
        }
    }
    @discardableResult
    private func emit(_ output: AgentOutput, for input: AgentInput) -> Bool {
        outputSequence += 1
        switch continuation.yield(
            OutputEnvelope(source: descriptor.id, input: input, output: output, sequence: outputSequence))
        {
        case .enqueued: return true
        case .dropped, .terminated:
            lifecycle = .failed
            queue.removeAll()
            worker?.cancel()
            continuation.finish()
            return false
        @unknown default:
            lifecycle = .failed
            queue.removeAll()
            worker?.cancel()
            continuation.finish()
            return false
        }
    }
}
