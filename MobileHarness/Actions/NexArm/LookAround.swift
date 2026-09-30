import AgentCore

extension NexArmActions {
    public enum LookAroundError: Error, Equatable, Sendable { case invalidRepetitions }
    public static func lookAround(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles"])
            count = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw LookAroundError.invalidRepetitions }
        try await perform(GestureRequest(gesture: .lookAround, repetitions: count), invocation)
        try Task.checkCancellation()
    }
}
