import AgentCore

/// Typed presentation operations; completion means the endpoint accepted the update.
public protocol UIUpdateCapability: Sendable {
    func present(_ text: String, invocation: ToolInvocation) async throws
    func presentTranscript(_ text: String, invocation: ToolInvocation) async throws
    func finishTranscript(invocation: ToolInvocation) async throws
    func beginReplyTurn(invocation: ToolInvocation) async throws
    func presentVoiceState(_ state: UITools.VoiceState, invocation: ToolInvocation) async throws
    func present(_ target: UITools.Gaze, invocation: ToolInvocation) async throws
}
