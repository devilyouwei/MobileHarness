import Foundation

/// Stateless namespace for scheduled speech actions.
public enum SpeechActions {
    /// Play an existing single-use audio handle; never synthesize text here.
    @Action(module: "Speech", title: "朗读回复", kind: .finite, completion: "Playback drained and audio lease released.")
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
            guard let parsed = UUID(uuidString: value) else { throw SpeechActionError.missingAudio }
            id = parsed
        } catch { throw SpeechActionError.missingAudio }
        try await play(id, invocation)
        try Task.checkCancellation()
    }
}

public enum SpeechActionError: Error { case missingAudio }
