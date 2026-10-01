import AgentCore

/// Typed presentation operations; completion means the endpoint accepted the update.
public protocol UIPresentationCapability: Sendable {
    func present(_ text: String, invocation: ActionInvocation) async throws
    func presentTranscript(_ text: String, invocation: ActionInvocation) async throws
    func finishTranscript(invocation: ActionInvocation) async throws
    func beginReplyTurn(invocation: ActionInvocation) async throws
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: ActionInvocation) async throws
    func presentExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) async throws
    func present(_ target: UIActions.Gaze, invocation: ActionInvocation) async throws
}
