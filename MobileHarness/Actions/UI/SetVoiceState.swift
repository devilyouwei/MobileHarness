extension UIActions {
    public enum VoiceState: String, Sendable { case listening, hearing, processing }
    public static func setVoiceState(
        invocation: ActionInvocation,
        present: @escaping @Sendable (VoiceState, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let state: VoiceState
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["state"])
            state = try arguments.requiredEnum("state", as: VoiceState.self)
        } catch { throw PresentationError.invalidCall }
        try await present(state, invocation)
        try Task.checkCancellation()
    }
}
