import AgentCore

public struct ActionInvocation: Sendable {
    public let envelope: OutputEnvelope
    public let call: ActionCall

    public init(envelope: OutputEnvelope, call: ActionCall) {
        self.envelope = envelope
        self.call = call
    }
}

public typealias ActionHandler = @Sendable (ActionInvocation) async throws -> Void
