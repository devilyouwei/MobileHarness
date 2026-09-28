import AgentCore
import Foundation
import StorageAudio

/// Playback and handle validation only. Synthesis belongs to SpeechSynthesisAgent.
public actor SpeechPlayback {
    private let store: SpeechAudioStore
    public init(store: SpeechAudioStore) { self.store = store }
    private func handle(_ invocation: ActionInvocation) throws -> (UUID, SpeechAudioStore.Owner) {
        guard invocation.call.parameters.count == 1,
            let value = invocation.call.parameters["audioID"], let id = UUID(uuidString: value)
        else { throw SpeechAudioError.missingAudio }
        return (
            id,
            .init(
                source: invocation.envelope.source, session: invocation.envelope.sessionID,
                input: invocation.envelope.inputID)
        )
    }
    public func play(
        _ invocation: ActionInvocation,
        using playback: @escaping @Sendable (SpeechAudio, ActionInvocation) async throws -> Void
    ) async throws {
        let (id, owner) = try handle(invocation)
        let audio = try await store.checkout(id, owner: owner)
        do {
            try await withTaskCancellationHandler {
                try await playback(audio, invocation)
                try Task.checkCancellation()
            } onCancel: {
                Task { try? await self.store.cancel(id, owner: owner) }
            }
            try await store.release(id, owner: owner)
        } catch {
            await store.fail(id, error: error)
            throw error
        }
    }
}
