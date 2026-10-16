import Foundation
import StorageCore
import Synchronization

/// PCM-specific ownership adapter over the shared process-local handle store.
public final class AudioCache: Sendable {
    public struct Owner: Sendable, Equatable {
        /// Opaque caller identity; Agent callers supply their raw ID at the boundary.
        public let source: String
        public let session: String
        public let input: String
        public init(source: String, session: String, input: String) {
            self.source = source
            self.session = session
            self.input = input
        }
        fileprivate var storage: StorageOwner {
            StorageOwner(namespace: "speech.pcm", source: source, session: session, input: input)
        }
    }

    private let rootAccess: CacheAccess?
    private let admission = CacheAccess()
    private let stopping = Mutex<Task<Void, Never>?>(nil)
    private let handles: MemoryLeaseStore<AudioStream>
    private let audioBytes: Int

    public convenience init(capacity: Int = 32, audioBytes: Int = 8_388_608) {
        self.init(capacity: capacity, audioBytes: audioBytes, rootAccess: nil)
    }
    init(capacity: Int = 32, audioBytes: Int = 8_388_608, rootAccess: CacheAccess?) {
        self.rootAccess = rootAccess
        precondition(audioBytes > 0)
        self.audioBytes = audioBytes
        handles = MemoryLeaseStore(
            capacity: capacity, queueTTL: nil, readyTTL: nil, errorTTL: nil
        ) { audio, error in await audio.fail(error) }
    }

    private func checkAdmission() throws {
        do {
            try rootAccess?.check()
            try admission.check()
        } catch { throw AudioCacheError.translating(error) }
    }
    public func register(_ id: String, owner: Owner, cancel: @escaping @Sendable () async -> Void) async throws {
        try checkAdmission()
        let audio = AudioStream(id: id, maximumBytes: audioBytes)
        do { try await handles.register(id, owner: owner.storage, value: audio, cancel: cancel) } catch {
            throw AudioCacheError.translating(error)
        }
    }

    public func begin(_ id: String) async throws -> AudioStream {
        try checkAdmission()
        do { return try await handles.begin(id) } catch { throw AudioCacheError.translating(error) }
    }

    public func complete(_ id: String) async {
        guard let audio = try? await handles.valueForCompletion(id) else { return }
        await audio.finish()
        await handles.complete(id)
    }

    public func validate(_ id: String, owner: Owner) async throws {
        try checkAdmission()
        do { try await handles.validate(id, owner: owner.storage) } catch { throw AudioCacheError.translating(error) }
    }

    public func checkout(_ id: String, owner: Owner) async throws -> AudioStream {
        try checkAdmission()
        do { return try await handles.checkout(id, owner: owner.storage) } catch {
            throw AudioCacheError.translating(error)
        }
    }

    public func release(_ id: String, owner: Owner) async throws {
        do { try await handles.release(id, owner: owner.storage) } catch { throw AudioCacheError.translating(error) }
    }

    public func cancel(_ id: String, owner: Owner) async throws {
        do { try await handles.cancel(id, owner: owner.storage) } catch { throw AudioCacheError.translating(error) }
    }

    public func fail(_ id: String, error: any Error) async { await handles.fail(id, error: error) }
    public func cancel(inputID: String, source: String) async {
        await handles.cancel(inputID: inputID, source: source, namespace: "speech.pcm")
        await handles.forgetTerminals(inputID: inputID, source: source, namespace: "speech.pcm")
    }
    public func cancel(sessionID: String) async {
        await handles.cancel(sessionID: sessionID, namespace: "speech.pcm")
        await handles.forgetTerminals(sessionID: sessionID, namespace: "speech.pcm")
    }
    public func shutdown() async {
        admission.close()
        let task = stopping.withLock { existing in
            if let existing { return existing }
            let task = Task { [handles] in await handles.shutdown() }
            existing = task
            return task
        }
        await task.value
    }
}
