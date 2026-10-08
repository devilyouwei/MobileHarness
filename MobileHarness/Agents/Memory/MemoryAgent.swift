import AgentCore
import Foundation

/// Memory business service entry point; domain workflows own their processing policy.
public actor MemoryAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let sessionID: UUID
    private var lifecycle = AgentLifecycle.registered
    private var processed = 0
    private var sequence: UInt64 = 0
    private var history = MemoryHistoryWorkflow()

    // MARK: - Registration

    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        try MemoryHistoryWorkflow.runtimeCapabilities(capabilities)
    }

    public init(sessionID: UUID, configuration: AgentConfiguration? = nil) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "Memory")
        guard configuration.agentID == .memory else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: .memory, name: "Memory", inputs: [.observation, .toolResult],
            outputs: [.toolCall, .control], capabilities: try Self.runtimeCapabilities(configuration.capabilities))
        self.sessionID = sessionID
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(8))
        outputs = stream.stream
        continuation = stream.continuation
    }

    // MARK: - Lifecycle

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
        history.reset()
        continuation.finish()
    }

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: processed)
    }

    // MARK: - Input processing

    public func receive(_ input: AgentInput) throws {
        try Task.checkCancellation()
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        guard input.sessionID == sessionID, !input.metadata.expired else { throw CommunicationError.invalidPayload }
        for step in try history.receive(input) {
            try emit(step.output, for: step.input)
        }
        processed += 1
    }

    // MARK: - Output admission

    private func emit(_ output: AgentOutput, for input: AgentInput) throws {
        sequence += 1
        let envelope = OutputEnvelope(source: descriptor.id, input: input, output: output, sequence: sequence)
        guard case .enqueued = continuation.yield(envelope) else {
            history.reset()
            lifecycle = .failed
            continuation.finish()
            throw CommunicationError.capacityExceeded
        }
    }
}
