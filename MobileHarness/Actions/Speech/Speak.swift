import ActionRuntime
import Foundation
import ModelKit

public enum SpeechActions {
    /// Completes only after all synthesized PCM has been played by the injected platform adapter.
    public static func speak(
        invocation: ActionInvocation,
        synthesis: any SpeechSynthesisCapability,
        locale: String = "zh-CN",
        play: @escaping @Sendable (AudioFrame, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let text = invocation.call.parameters["text"], text.utf8.count <= 2_000,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ActionExecutionError.invalidText }
        let session = try await synthesis.synthesize(
            SpeechSynthesisRequest(
                text: text, locale: locale,
                context: InferenceContext(
                    requestID: invocation.envelope.inputID,
                    conversationID: invocation.envelope.sessionID)))
        defer { session.cancel() }
        try await withTaskCancellationHandler {
            var bytes = 0
            var completed = false
            for try await event in session.events {
                try Task.checkCancellation()
                guard !completed else { throw CapabilityError.invalidRequest("Event after TTS completion") }
                switch event {
                case .audio(let frame):
                    guard frame.data.count <= 8_388_608 - bytes else { throw CapabilityError.eventTooLarge }
                    bytes += frame.data.count
                    try await play(frame, invocation)
                case .finished:
                    completed = true
                }
            }
            try Task.checkCancellation()
            guard completed, bytes > 0 else {
                throw CapabilityError.unavailable("语音合成没有生成可播放的音频")
            }
        } onCancel: {
            session.cancel()
        }
    }
}
