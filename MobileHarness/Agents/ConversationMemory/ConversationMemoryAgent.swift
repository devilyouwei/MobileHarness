import AgentCore
import Foundation

/// Deterministic history role; never constructs UI, stores or model services.
public actor ConversationMemoryAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let sessionID: UUID
    private var lifecycle = AgentLifecycle.registered
    private var processed = 0
    private var sequence: UInt64 = 0
    private var pending: (input: AgentInput, callID: UUID)?
    private static let deletion = InternalTool(path: "History.Conversation.delete", required: ["id"])
    private static let presentation = InternalTool(path: "UI.HistoryPresentation.showHistory")
    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        try capabilities.adding(internalTools: [presentation, deletion])
    }
    public init(sessionID: UUID, configuration: AgentConfiguration? = nil) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "ConversationMemory")
        guard configuration.agentID == .conversationMemory else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: .conversationMemory, name: "ConversationMemory", inputs: [.observation, .toolResult],
            outputs: [.toolCall, .control], capabilities: try Self.runtimeCapabilities(configuration.capabilities))
        self.sessionID = sessionID
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(8))
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
    }
    public func stop() {
        lifecycle = .stopped
        pending = nil
        continuation.finish()
    }
    public func receive(_ input: AgentInput) throws {
        try Task.checkCancellation()
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        guard input.sessionID == sessionID, !input.metadata.expired else { throw CommunicationError.invalidPayload }
        switch input.payload {
        case .toolResult(let result):
            guard input.metadata.source == "runtime", let active = pending, active.callID == result.callID else {
                throw CommunicationError.invalidPayload
            }
            pending = nil
            if result.isError {
                try emit(.control("history.delete.failed"), for: active.input)
            } else {
                try emit(.toolCall(Self.presentation.call([:])), for: active.input)
            }
        case .observation(let message):
            guard message.contract == ConversationMemoryIntent.contract, let intent = message.historyIntent else {
                throw CommunicationError.invalidPayload
            }
            switch intent {
            case .cancel(let id):
                guard input.metadata.source == "runtime", id == input.id, pending == nil || pending?.input.id == id
                else {
                    throw CommunicationError.invalidPayload
                }
                pending = nil
                try emit(.control("history.cancelled"), for: input)
            case .refresh:
                guard input.metadata.source == "user" else { throw CommunicationError.invalidPayload }
                guard pending == nil else { throw CommunicationError.capacityExceeded }
                try emit(.toolCall(Self.presentation.call([:])), for: input)
            case .delete(let id):
                guard input.metadata.source == "user" else { throw CommunicationError.invalidPayload }
                guard pending == nil else { throw CommunicationError.capacityExceeded }
                let call = try Self.deletion.call(["id": id.uuidString])
                pending = (input, call.id)
                try emit(.toolCall(call), for: input)
            }
        default: throw CommunicationError.invalidPayload
        }
        processed += 1
    }
    private func emit(_ output: AgentOutput, for input: AgentInput) throws {
        sequence += 1
        let envelope = OutputEnvelope(source: descriptor.id, input: input, output: output, sequence: sequence)
        guard case .enqueued = continuation.yield(envelope) else {
            pending = nil
            lifecycle = .failed
            continuation.finish()
            throw CommunicationError.capacityExceeded
        }
    }
    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: processed)
    }
}
