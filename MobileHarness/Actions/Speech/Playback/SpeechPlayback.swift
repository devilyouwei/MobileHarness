import Foundation
import FunctionContracts
import StorageCache
import StorageCore
import Synchronization

/// Typed audio checkout, playback and cleanup only. Synthesis belongs to Assistant.
public actor SpeechPlayback {
    private let store: AudioCache
    public init(store: AudioCache) { self.store = store }
    public func play(
        audioID id: String, invocation: any FunctionInput,
        using playback: @escaping @Sendable (AudioStream, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let owner = AudioCache.Owner(
            source: invocation.context.source, session: invocation.context.sessionID,
            input: invocation.context.inputID)
        let audio = try await store.checkout(id, owner: owner)
        let cancellation = Mutex<Task<Void, Never>?>(nil)
        do {
            try await withTaskCancellationHandler {
                try await playback(audio, invocation)
                try Task.checkCancellation()
            } onCancel: {
                cancellation.withLock { task in
                    task = Task {
                        do { try await self.store.cancel(id, owner: owner) } catch {
                            await self.store.fail(id, error: error)
                        }
                    }
                }
            }
            try await store.release(id, owner: owner)
        } catch {
            let cleanup = cancellation.withLock { $0 }
            await cleanup?.value
            await store.fail(id, error: error)
            throw error
        }
    }
}
