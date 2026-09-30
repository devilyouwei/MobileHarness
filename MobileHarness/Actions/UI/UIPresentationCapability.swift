import AgentCore

/// Typed presentation operations; completion means the endpoint accepted the update.
public protocol UIPresentationCapability: Sendable {
    func presentExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) async throws
}
