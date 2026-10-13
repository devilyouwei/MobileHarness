import Foundation
import FunctionContracts

/// Speech.Playback function ownership; current invocation paths remain compatible.
extension SpeechActions {
    /// Play an existing single-use audio handle; never synthesize text here.
    @Action(
        domain: "Speech", module: "Playback", title: "朗读回复", kind: .finite,
        completion: "Playback drained and audio lease released.", timeout: .seconds(300))
    public static func speak(
        invocation: any FunctionInput,
        using play: @escaping @Sendable (UUID, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let id: UUID
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["audioID"])
            let value = try arguments.requiredString("audioID", maximumUTF8Bytes: 36, allowBlank: false)
            guard let parsed = UUID(uuidString: value) else { throw SpeechActionError.missingAudio }
            id = parsed
        } catch { throw SpeechActionError.missingAudio }
        try await play(id, invocation)
        try Task.checkCancellation()
    }
}
