import AgentCore

/// Immediate Tool context retains trusted session, turn and output sequence; it has no scheduler state.
public struct ToolInvocation: Sendable {
    public let call: ToolCall
    public let envelope: OutputEnvelope
    public init(call: ToolCall, envelope: OutputEnvelope) {
        self.call = call
        self.envelope = envelope
    }
}
