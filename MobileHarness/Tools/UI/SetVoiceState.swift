import AgentCore

extension UITools {
    public enum VoiceState: String, Sendable { case listening, hearing, processing }
    public static func setVoiceState(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (VoiceState, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let state: VoiceState
        do {
            let arguments = CallArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["state"])
            state = try arguments.requiredEnum("state", as: VoiceState.self)
        } catch { throw PresentationError.invalidCall }
        try await present(state, invocation)
        try Task.checkCancellation()
    }
}
