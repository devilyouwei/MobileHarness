import ToolRuntime

public struct RobotToolModule: ToolModule {
    private let aim: @Sendable (Double, Double, ToolInvocation) async throws -> Void

    public init(aim: @escaping @Sendable (Double, Double, ToolInvocation) async throws -> Void) {
        self.aim = aim
    }

    public var definitions: [ToolDefinition] {
        [
            RobotTools.aimDefinition(completing: { [aim] call, context in
                try await RobotTools.aim(invocation: ToolInvocation(call: call, context: context), using: aim)
            })
        ]
    }
}
