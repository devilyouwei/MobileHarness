import AgentCore
import Foundation
import ModelKit
import StorageChat

/// Model-backed assistant; concrete model selection belongs exclusively to the composition root.
public actor AssistantAgent: Agent {
    private var resultInbox = ActionResultInbox()
    public func actionResults() -> [ActionResult] { resultInbox.results }
    public nonisolated let descriptor: AgentDescriptor
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
    private var begunSession: UUID?
    private var begunTurn: ConversationTurn?
    private var outputSequence: UInt64 = 0
    private let conversations: ConversationHistoryStore
    private let modelName: @Sendable () async throws -> String
    private var generationFinishReason: String?

    public init(
        capacity: Int = 32, chat: any ChatCapability,
        configuration: AgentConfiguration? = nil,
        conversations: ConversationHistoryStore = ConversationHistoryStore(),
        modelName: @escaping @Sendable () async throws -> String = { "Unspecified model" }
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "Assistant")
        guard configuration.agentID == .assistant else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Assistant", inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.actionCall, .toolCall, .control, .scheduling],
            capabilities: try Self.runtimeCapabilities(configuration.capabilities))
        precondition(capacity > 0)
        self.capacity = capacity
        self.chat = chat
        self.conversations = conversations
        self.modelName = modelName
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(256))
        outputs = stream.stream
        continuation = stream.continuation
    }
    /// Shared with explicit model diagnostics; capability declarations remain in Assistant JSON.
    public nonisolated static func systemPrompt(capabilities: CapabilityRegistry) throws
        -> String
    {
        "You are a voice assistant on a phone. Answer directly and concisely, usually in no more than three short sentences. Reply in the user's language; speech currently supports Mandarin and English. Ordinary replies should be natural text; all text is automatically converted to audio and played. Use tags when an Action or explicit ordering is needed. Output speakable plain text and declared Action tags only, without Markdown, emoji or reasoning commentary. Spell out English decimals and currency in words. Do not claim an operation succeeded without confirmation.\n"
            + (try CapabilityContextBuilder.build(capabilities, speechChannel: "Speech"))
    }

    private static let beginReply = InternalTool(path: "UI.beginReplyTurn")
    private static let playback = InternalAction(
        module: "Speech", function: "speak", channel: "Speech", required: ["audioID"])
    private static let caption = InternalTool(path: "UI.print", required: ["text"])

    public nonisolated static func runtimeCapabilities(_ model: CapabilityRegistry) throws -> CapabilityRegistry {
        try model.adding(internalActions: [playback], internalTools: [beginReply, caption])
    }

    /// Agent-owned text expansion. Speech text is replaced with an audioID before Gateway admission.
    public nonisolated static func mapText(_ text: String, channel: String?) throws -> [GenerationEvent] {
        [
            .action(
                ActionCall(actionPath: playback.path, channel: channel ?? playback.channel, parameters: ["text": text])),
            .tool(try caption.call(["text": text])),
        ]
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
        if case .actionResult(let result) = input.payload {
            guard input.metadata.source == "runtime", result.owner.agent == descriptor.id,
                result.owner.sessionID == input.sessionID
            else { throw CommunicationError.unauthorized }
            resultInbox.accept(result)
            return
        }
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
            // Unsupported input is rejected by the descriptor; receipts are handled before this switch.
            case .image, .audio, .observation, .actionResult, .activityEvent: break
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
        let call = try Self.beginReply.call([:])
        guard emit(.toolCall(call), for: input) else { throw HarnessError.queueFull }
        begunSession = input.sessionID
        begunTurn = turn
    }
    private func generate(_ text: String, input: AgentInput, using chat: any ChatCapability) async {
        defer {
            activeInput = nil
            worker = nil
            drain()
        }
        var recorded = false
        generationFinishReason = nil
        do {
            let record = try await conversations.begin(
                id: input.id, user: text,
                system: Self.systemPrompt(capabilities: descriptor.capabilities),
                model: try await modelName())
            recorded = true
            try Task.checkCancellation()
            try beginReplyTurn(input)
            let messages = record.request.map { message in
                ChatMessage(
                    role: message.role == .system ? .system : (message.role == .user ? .user : .assistant),
                    content: message.content)
            }
            let tools: [ChatToolDefinition]
            if await chat.supportsToolCalls {
                tools = try descriptor.capabilities.tools.compactMap { registration in
                    guard let definition = registration.definition else { return nil }
                    return try ChatToolDefinition(declaration: JSONEncoder().encode(definition))
                }
            } else {
                tools = []
            }
            let request = try ChatRequest(
                messages: messages,
                context: InferenceContext(requestID: input.id, conversationID: input.sessionID),
                maximumOutputTokens: record.maximumOutputTokens, temperature: record.temperature, tools: tools)
            _ = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await self.collect(request, input: input, using: chat) }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw CapabilityError.unavailable("Assistant generation timed out")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? ""
            }
            try Task.checkCancellation()
            try await conversations.finish(input.id, state: .completed, reason: generationFinishReason)
            guard lifecycle == .running || lifecycle == .paused else { return }
            emit(.control("assistant.finished"), for: input)
        } catch {
            var failure = String(describing: error)
            if recorded {
                do {
                    try await conversations.finish(
                        input.id, state: Task.isCancelled || error is CancellationError ? .cancelled : .failed,
                        reason: generationFinishReason, error: failure)
                } catch { failure += "; history persistence failed: \(error)" }
            }
            guard !Task.isCancelled, lifecycle == .running || lifecycle == .paused else { return }
            emit(.control("assistant.error: \(failure)"), for: input)
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
            var generator = AgentGenerator(capabilities: descriptor.capabilities, textMapping: Self.mapText)
            var emittedCalls = 0
            for try await event in session.events {
                try Task.checkCancellation()
                if case .text(let delta) = event { try await conversations.append(delta, to: input.id) }
                guard !finished else { throw CapabilityError.invalidRequest("Events after chat completion") }
                switch event {
                case .text(let delta):
                    text += delta
                    try await emitFunctions(generator.append(delta), for: input, count: &emittedCalls)
                case .toolCall(let native):
                    let call = try ToolCallParser.parse(
                        id: UUID(), alias: native.name, argumentsJSON: Data(native.argumentsJSON.utf8),
                        capabilities: descriptor.capabilities)
                    try await emitFunctions([.tool(call)], for: input, count: &emittedCalls)
                case .finished(let reason):
                    switch reason {
                    case .stop: generationFinishReason = "stop"
                    case .lengthLimit: generationFinishReason = "lengthLimit"
                    case .toolCalls: generationFinishReason = "toolCalls"
                    }
                    finished = true
                }
            }
            guard finished, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || emittedCalls > 0 else {
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
            var generator = AgentGenerator(capabilities: descriptor.capabilities, textMapping: Self.mapText)
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
            if case .tool(let call) = event {
                try Task.checkCancellation()
                guard count < 120 else { throw GenerationError.limitExceeded }
                count += 1
                guard emit(.toolCall(call), for: input) else { throw HarnessError.queueFull }
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
                let report = try await port.sendResult(.speechSynthesis(request), parent: input, to: target)
                guard report.delivered.contains(target), report.rejected.isEmpty else {
                    continue
                }
                do {
                    try Task.checkCancellation()
                    call = try Self.playback.call(["audioID": request.audioID.uuidString], channel: original.channel)
                    guard emit(.actionCall(call), for: input) else { throw HarnessError.queueFull }
                } catch {
                    // Explicit command admission has its own deadline and preserves the owning input ID.
                    let cleanup = input
                    let cleanupTask = Task.detached {
                        try await port.sendResult(.cancelSpeech(request.audioID), parent: cleanup, to: target)
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
