import Foundation
import StorageAudio

/// Stateless namespace for scheduled speech actions.
public enum SpeechActions {
    /// Play an existing single-use audio handle; never synthesize text here.
    public static func speak(
        invocation: ActionInvocation,
        using play: @escaping @Sendable (UUID, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let id: UUID
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["audioID"])
            let value = try arguments.requiredString("audioID", maximumUTF8Bytes: 36, allowBlank: false)
            guard let parsed = UUID(uuidString: value) else { throw SpeechAudioError.missingAudio }
            id = parsed
        } catch { throw SpeechAudioError.missingAudio }
        try await play(id, invocation)
        try Task.checkCancellation()
    }
}
