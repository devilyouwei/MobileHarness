import AgentCore
import Foundation

public enum ConversationMemoryIntent: String, Sendable {
    case refresh = "history.refresh"
    public func input(sessionID: UUID) -> AgentInput {
        let payload = InputPayload.event(rawValue)
        return AgentInput(
            sessionID: sessionID, payload: payload, metadata: InputMetadata(payload: payload, source: "user"))
    }
}

/// Deterministic history role; never constructs UI, stores or model services.
public actor ConversationMemoryAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let sessionID: UUID
    private var lifecycle = AgentLifecycle.registered
    private var processed = 0
    private var sequence: UInt64 = 0
    private static let presentation = InternalTool(path: "UI.showHistory")
    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        try capabilities.adding(internalTools: [presentation])
    }
    public init(sessionID: UUID, configuration: AgentConfiguration? = nil) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "ConversationMemory")
        guard configuration.agentID == .conversationMemory else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: .conversationMemory, name: "ConversationMemory", inputs: [.event],
            outputs: [.toolCall], capabilities: try Self.runtimeCapabilities(configuration.capabilities))
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
        continuation.finish()
    }
    public func receive(_ input: AgentInput) throws {
        try Task.checkCancellation()
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        guard input.metadata.source == "user", input.sessionID == sessionID, !input.metadata.expired,
            case .event(let raw) = input.payload, ConversationMemoryIntent(rawValue: raw) == .refresh
        else { throw CommunicationError.invalidPayload }
        sequence += 1
        let output = OutputEnvelope(
            source: descriptor.id, input: input, output: .toolCall(try Self.presentation.call([:])), sequence: sequence)
        guard case .enqueued = continuation.yield(output) else {
            lifecycle = .failed
            continuation.finish()
            throw CommunicationError.capacityExceeded
        }
        processed += 1
    }
    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: processed)
    }
}
