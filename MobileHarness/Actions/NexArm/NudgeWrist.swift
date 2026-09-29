extension NexArmActions {
    public enum NudgeError: Error, Equatable, Sendable { case invalidDelta }

    /// A supervised diagnostic nudge, not a general robot motion API.
    public static func nudgeWrist(
        invocation: ActionInvocation,
        using move: @escaping @Sendable (Int, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let delta: Int
        do {
            let args = ActionArguments(invocation.call.parameters)
            try args.validateAllowedKeys(["degrees"])
            delta = try args.requiredInt("degrees", range: -2...2)
            guard delta != 0 else { throw NudgeError.invalidDelta }
        } catch { throw NudgeError.invalidDelta }
        try await move(delta, invocation)
        try Task.checkCancellation()
    }
}
