import AgentCore

extension NexArmActions {
    public enum WaveWristError: Error, Equatable, Sendable { case invalidRepetitions }
    public static func waveWrist(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["count"])
            count = try arguments.requiredInt("count", range: 1...3)
        } catch { throw WaveWristError.invalidRepetitions }
        try await perform(GestureRequest(gesture: .wave, repetitions: count), invocation)
        try Task.checkCancellation()
    }
}
