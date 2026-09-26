import ActionRuntime

extension UIActions {
    public enum VoiceState: String, Sendable { case listening, hearing, processing }
    public static func setVoiceState(
        invocation: ActionInvocation,
        present: @escaping @Sendable (VoiceState, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let value = invocation.call.parameters["state"], let state = VoiceState(rawValue: value) else {
            throw ActionExecutionError.invalidCall
        }
        try await present(state, invocation)
        try Task.checkCancellation()
    }
}
