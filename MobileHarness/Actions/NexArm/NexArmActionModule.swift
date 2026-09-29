import AgentCore

/// Explicit opt-in module; absent from the iPhone built-in catalog.
public struct NexArmActionModule: ActionModule {
    private let move: @Sendable (Int, ActionInvocation) async throws -> Void
    public init(move: @escaping @Sendable (Int, ActionInvocation) async throws -> Void) { self.move = move }
    public var definitions: [ActionDefinition] {
        [
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "nudgeWrist"), kind: .finite,
                completion: "Controller-reported wrist position within six counts in three consecutive samples."
            ) { [move] invocation in
                try await NexArmActions.nudgeWrist(invocation: invocation, using: move)
            }
        ]
    }
}
