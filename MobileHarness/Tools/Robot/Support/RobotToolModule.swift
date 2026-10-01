import AgentCore

public struct RobotToolModule: ToolModule {
    private let aim: @Sendable (Double, Double, ToolInvocation) async throws -> Void

    public init(aim: @escaping @Sendable (Double, Double, ToolInvocation) async throws -> Void) {
        self.aim = aim
    }

    public var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                path: "Robot.aim",
                completing: { [aim] call, envelope in
                    try await RobotTools.aim(invocation: ToolInvocation(call: call, envelope: envelope), using: aim)
                })
        ]
    }
}
