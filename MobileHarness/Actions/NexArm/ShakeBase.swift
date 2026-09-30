import AgentCore

extension NexArmActions {
    public enum ShakeError: Error, Equatable, Sendable { case invalidCycles }

    public static func shakeBase(
        invocation: ActionInvocation,
        using move: @escaping @Sendable (Int, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let cycles: Int
        do {
            let args = ActionArguments(invocation.call.parameters)
            try args.validateAllowedKeys(["cycles"])
            cycles = try args.requiredInt("cycles", range: 1...3)
        } catch { throw ShakeError.invalidCycles }
        try await move(cycles, invocation)
        try Task.checkCancellation()
    }
}

/// Model-callable bounded base sweep; the host must supply an explicit device binding.
public struct NexArmBaseActionModule: ActionModule {
    private let move: @Sendable (Int, ActionInvocation) async throws -> Void
    public init(move: @escaping @Sendable (Int, ActionInvocation) async throws -> Void) { self.move = move }
    public var definitions: [ActionDefinition] {
        [
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "shakeBase"), kind: .finite,
                completion:
                    "Every fixed left/right waypoint converges in controller telemetry; the performance finishes at its fixed home pose."
            ) { [move] invocation in
                try await NexArmActions.shakeBase(invocation: invocation, using: move)
            }
        ]
    }
}
