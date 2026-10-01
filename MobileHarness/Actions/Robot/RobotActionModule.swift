import AgentCore

public struct RobotActionModule: ActionModule {
    private let aim: @Sendable (Double, Double, ActionInvocation) async throws -> Void

    public init(aim: @escaping @Sendable (Double, Double, ActionInvocation) async throws -> Void) {
        self.aim = aim
    }

    public var definitions: [ActionDefinition] {
        [
            ActionDefinition(
                path: ActionPath(module: "Robot", function: "aim"), kind: .finite,
                completion: "The byte transport accepted one six-position frame. Joint settling is not joined.",
                handler: { [aim] invocation in
                    try await RobotActions.aim(invocation: invocation, using: aim)
                })
        ]
    }
}
