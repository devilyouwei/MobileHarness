import AgentCore

/// Typed presentation operations; completion means the endpoint accepted the update.
public protocol UIPresentationCapability: Sendable {
    func presentExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) async throws
}

public struct UIActionModule: ActionModule {
    private let presentation: any UIPresentationCapability
    public init(presentation: any UIPresentationCapability) { self.presentation = presentation }
    public var definitions: [ActionDefinition] {
        [
            ActionDefinition(
                path: ActionPath(module: "UI", function: "express"), displayName: "调整表情", kind: .state,
                completion:
                    "Presentation policy accepted expression target or rejected a stale update; animation is not joined.",
                handler: { [presentation] invocation in
                    try await UIActions.express(invocation: invocation) {
                        try await presentation.presentExpression($0, invocation: $1)
                    }
                })
        ]
    }
}
