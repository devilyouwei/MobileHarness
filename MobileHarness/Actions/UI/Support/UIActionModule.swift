import ActionRuntime

/// Finite transition/restore acknowledgments and independent persistent-state commitment.
public protocol UIPresentationCapability: Sendable {
    func presentExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) async throws
    func restoreExpression(invocation: ActionInvocation) async throws
    func setExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) async throws
}

public struct UIActionModule: ActionModule {
    private let presentation: any UIPresentationCapability
    public init(presentation: any UIPresentationCapability) { self.presentation = presentation }
    public var definitions: [ActionDefinition] {
        [
            UIActions.expressDefinition(handler: { [presentation] invocation in
                try await UIActions.express(
                    invocation: invocation,
                    using: {
                        try await presentation.presentExpression($0, invocation: $1)
                    },
                    restoring: {
                        try await presentation.restoreExpression(invocation: $0)
                    })
            }),
            UIActions.setExpressionDefinition(handler: { [presentation] invocation in
                try await UIActions.setExpression(invocation: invocation) {
                    try await presentation.setExpression($0, invocation: $1)
                }
            }),
        ]
    }
}
