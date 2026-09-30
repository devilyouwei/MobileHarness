import AgentCore

extension NexArmActions {
    public enum DanceError: Error, Equatable, Sendable { case invalidRepetitions }
    public static func dance(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles"])
            count = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw DanceError.invalidRepetitions }
        try await perform(GestureRequest(gesture: .dance, repetitions: count), invocation)
        try Task.checkCancellation()
    }
}
