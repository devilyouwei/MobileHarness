import AgentCore
import Foundation
import Storage

/// PCM-specific ownership adapter over the shared process-local handle store.
public final class SpeechAudioStore: Sendable {
    public struct Owner: Sendable, Equatable {
        public let source: AgentID
        public let session: UUID
        public let input: UUID
        public init(source: AgentID, session: UUID, input: UUID) {
            self.source = source
            self.session = session
            self.input = input
        }
        fileprivate var storage: StorageOwner {
            StorageOwner(namespace: "speech.pcm", source: source.rawValue, session: session, input: input)
        }
    }

    private let handles: MemoryLeaseStore<SpeechAudio>
    private let audioBytes: Int
    private let waitTimeout: Duration

    public init(
        capacity: Int = 32, audioBytes: Int = 2_097_152,
        queueTTL: Duration = .seconds(60), readyTTL: Duration = .seconds(60),
        errorTTL: Duration = .seconds(30), waitTimeout: Duration = .seconds(3)
    ) {
        precondition(audioBytes > 0 && waitTimeout > .zero)
        self.audioBytes = audioBytes
        self.waitTimeout = waitTimeout
        handles = MemoryLeaseStore(
            capacity: capacity, queueTTL: queueTTL, readyTTL: readyTTL, errorTTL: errorTTL
        ) { audio, error in await audio.fail(error) }
    }

    public func register(_ id: UUID, owner: Owner, cancel: @escaping @Sendable () async -> Void) async throws {
        let audio = SpeechAudio(id: id, maximumBytes: audioBytes, waitTimeout: waitTimeout)
        do { try await handles.register(id, owner: owner.storage, value: audio, cancel: cancel) } catch {
            throw SpeechAudioError.translating(error)
        }
    }

    public func begin(_ id: UUID) async throws -> SpeechAudio {
        do { return try await handles.begin(id) } catch { throw SpeechAudioError.translating(error) }
    }

    public func complete(_ id: UUID) async {
        guard let audio = try? await handles.valueForCompletion(id) else { return }
        await audio.finish()
        await handles.complete(id)
    }

    public func validate(_ id: UUID, owner: Owner) async throws {
        do { try await handles.validate(id, owner: owner.storage) } catch { throw SpeechAudioError.translating(error) }
    }

    public func checkout(_ id: UUID, owner: Owner) async throws -> SpeechAudio {
        do { return try await handles.checkout(id, owner: owner.storage) } catch {
            throw SpeechAudioError.translating(error)
        }
    }

    public func release(_ id: UUID, owner: Owner) async throws {
        do { try await handles.release(id, owner: owner.storage) } catch { throw SpeechAudioError.translating(error) }
    }

    public func cancel(_ id: UUID, owner: Owner) async throws {
        do { try await handles.cancel(id, owner: owner.storage) } catch { throw SpeechAudioError.translating(error) }
    }

    public func fail(_ id: UUID, error: any Error) async { await handles.fail(id, error: error) }
    public func cancel(inputID: UUID, source: AgentID) async {
        await handles.cancel(inputID: inputID, source: source.rawValue, namespace: "speech.pcm")
    }
    public func cancel(sessionID: UUID) async { await handles.cancel(sessionID: sessionID, namespace: "speech.pcm") }
    public func shutdown() async { await handles.shutdown() }
}
