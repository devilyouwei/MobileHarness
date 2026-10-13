import Foundation
import FunctionContracts

/// UI.VoiceState function ownership; current invocation paths remain compatible.
extension UIActions {
    @Action(
        domain: "UI", module: "VoiceState", title: "setVoiceState", timeout: .seconds(5))
    public static func setVoiceState(
        invocation: any FunctionInput,
        using present: @escaping @Sendable (VoiceState, any FunctionInput) async throws -> Void
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
