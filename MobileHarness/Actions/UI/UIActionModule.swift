import AgentCore

public struct UIActionModule: ActionModule {
    private let presentation: any UIPresentationCapability
    public init(presentation: any UIPresentationCapability) { self.presentation = presentation }
    public var definitions: [ActionDefinition] {
        [
            ActionDefinition(
                path: ActionPath(module: "UI", function: "express"), kind: .state,
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
