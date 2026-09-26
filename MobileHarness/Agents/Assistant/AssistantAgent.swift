import AgentCore
import Foundation
import ModelKit

/// Model-backed assistant; concrete model selection belongs exclusively to the composition root.
public actor AssistantAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    private let textActions: [String]
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private var lifecycle: AgentLifecycle = .registered
    private var queue: [AgentInput] = []
    private var processed = 0
    private let capacity: Int
    private let chat: any ChatCapability
    private var worker: Task<Void, Never>?
    private var activeInput: AgentInput?
    private var historySession: UUID?
    private var history: [ChatMessage] = []

    public init(
        capacity: Int = 32, chat: any ChatCapability,
        configuration: AgentConfiguration? = nil
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "Assistant")
        guard configuration.agentID == .assistant else { throw AgentConfigurationError.identityMismatch }
        guard !configuration.textActions.isEmpty else { throw AgentConfigurationError.invalidField("textActions") }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Assistant", inputs: [.text, .event, .toolResult],
            outputs: [.actionCall, .toolCall, .control], capabilities: configuration.capabilities)
        textActions = configuration.textActions
        precondition(capacity > 0)
        self.capacity = capacity
        self.chat = chat
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(128))
        outputs = stream.stream
        continuation = stream.continuation
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
            processed += 1
            switch input.payload {
            case .text(let text):
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
            case .image, .audio, .observation: break  // Rejected by the descriptor before admission.
            case .event(let event): emitImmediate("事件：\(event)", for: input)
            case .toolResult(let result): emitImmediate(result.value, for: input)
            }
        }
    }
    private func generate(_ text: String, input: AgentInput, using chat: any ChatCapability) async {
        defer {
            activeInput = nil
            worker = nil
            drain()
        }
        do {
            if historySession != input.sessionID {
                history.removeAll()
                historySession = input.sessionID
            }
            let messages =
                [
                    ChatMessage(
                        role: .system,
                        content: "你是手机上的语音助手。直接、简洁地回答，通常不超过三句话。使用用户的语言，不输出思考过程。不要声称已执行未执行的操作。\n"
                            + CapabilityContextBuilder.build(descriptor.capabilities))
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
                    try emitFunctions(generator.append(delta), for: input, count: &emittedCalls)
                case .finished: finished = true
                }
            }
            guard finished, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CapabilityError.unavailable("LLM returned no completed answer")
            }
            try emitFunctions(generator.finish(), for: input, count: &emittedCalls)
            guard emittedCalls > 0 else { throw CapabilityError.unavailable("LLM returned no speakable answer") }
            return text
        } onCancel: {
            session.cancel()
        }
    }
    private func emitImmediate(_ text: String, for input: AgentInput) {
        do {
            guard text.utf8.count <= 2000 else { throw CapabilityError.eventTooLarge }
            var generator = try AgentGenerator(capabilities: descriptor.capabilities, textActions: textActions)
            var count = 0
            try emitFunctions(
                generator.append(AgentGenerator.escapeText(text)) + generator.finish(), for: input, count: &count)
            emit(.control("assistant.finished"), for: input)
        } catch {
            emit(.control("assistant.error: \(error)"), for: input)
        }
    }
    private func emitFunctions(_ calls: [ActionCall], for input: AgentInput, count: inout Int) throws {
        for call in calls {
            try Task.checkCancellation()
            guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
            guard count < 120 else { throw GenerationError.limitExceeded }
            count += 1
            guard emit(.actionCall(call), for: input) else { throw HarnessError.queueFull }
        }
    }
    @discardableResult
    private func emit(_ output: AgentOutput, for input: AgentInput) -> Bool {
        switch continuation.yield(OutputEnvelope(source: descriptor.id, input: input, output: output)) {
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
