import ActionRuntime
import Foundation

/// UI.VoiceState function ownership; current invocation paths remain compatible.
extension UIActions {
    @Tool(path: "UI.VoiceState.setVoiceState", title: "setVoiceState")
    public static func setVoiceState(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (VoiceState, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let state: VoiceState
        do {
            let arguments = ToolArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["state"])
            state = try arguments.requiredEnum("state", as: VoiceState.self)
        } catch { throw PresentationError.invalidCall }
        try await present(state, invocation)
        try Task.checkCancellation()
    }
}
