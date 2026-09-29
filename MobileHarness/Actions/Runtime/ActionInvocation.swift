import AgentCore
import Foundation

public struct ActionInvocation: Sendable {
    public let executionID: UUID
    public let envelope: OutputEnvelope
    public let call: ActionCall

    /// The envelope is the single source of call identity; non-Action outputs cannot be invoked.
    public init(envelope: OutputEnvelope) throws {
        guard case .actionCall(let call) = envelope.output else { throw ActionExecutionError.invalidInvocation }
        self.executionID = UUID()
        self.envelope = envelope
        self.call = call
    }

    /// Convenience for trusted composition/tests; creates the envelope from the same call.
    public init(source: AgentID, input: AgentInput, call: ActionCall, sequence: UInt64 = 0) {
        self.executionID = UUID()
        self.envelope = OutputEnvelope(source: source, input: input, output: .actionCall(call), sequence: sequence)
        self.call = call
    }
}

public typealias ActionHandler = @Sendable (ActionInvocation) async throws -> Void
