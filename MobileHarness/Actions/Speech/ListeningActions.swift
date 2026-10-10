import Foundation
import FunctionContracts

extension SpeechActions {
    /// SpeechPerception uses this fixed registered function; it is absent from model catalogs.
    @Action(
        domain: "Speech", module: "Listening", title: "聆听状态", kind: .finite,
        completion: "Listening policy accepted; physical capture follows user consent and playback barriers.",
        serializationKey: "Listening")
    public static func update(
        invocation: any FunctionInput,
        using apply: @escaping @Sendable (Bool, Bool, UInt64) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["enabled", "paused", "revision"])
        let enabled = try arguments.requiredString("enabled", maximumUTF8Bytes: 5)
        let paused = try arguments.requiredString("paused", maximumUTF8Bytes: 5)
        let rawRevision = try arguments.requiredString("revision", maximumUTF8Bytes: 20)
        guard ["true", "false"].contains(enabled), ["true", "false"].contains(paused),
            let revision = UInt64(rawRevision), revision > 0
        else { throw ActionArguments.ValidationError.invalidValue("listening") }
        try await apply(enabled == "true", paused == "true", revision)
    }
}
