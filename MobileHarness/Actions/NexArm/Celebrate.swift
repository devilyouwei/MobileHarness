import AgentCore

extension NexArmActions {
    public enum CelebrateError: Error, Equatable, Sendable { case invalidRepetitions }
    public static func celebrate(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles"])
            count = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw CelebrateError.invalidRepetitions }
        try await perform(GestureRequest(gesture: .celebrate, repetitions: count), invocation)
        try Task.checkCancellation()
    }
}
