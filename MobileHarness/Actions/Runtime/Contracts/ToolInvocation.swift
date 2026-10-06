/// Immediate Tool context retains trusted session, turn and output sequence; it has no scheduler state.
public struct ToolInvocation: Sendable {
    public let call: ToolRequest
    public let context: ToolExecutionContext
    public init(call: ToolRequest, context: ToolExecutionContext) {
        self.call = call
        self.context = context
    }
}
