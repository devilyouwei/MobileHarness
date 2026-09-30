import AgentCore

extension NexArmActions {
    public enum TiltDirection: String, Sendable { case left, right }
    public enum TiltWristError: Error, Equatable, Sendable { case invalidDirection }
    public static func tiltWrist(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let direction: TiltDirection
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["direction"])
            direction = try arguments.requiredEnum("direction", as: TiltDirection.self)
        } catch { throw TiltWristError.invalidDirection }
        try await perform(
            GestureRequest(gesture: direction == .left ? .tiltLeft : .tiltRight, repetitions: 1), invocation)
        try Task.checkCancellation()
    }
}
