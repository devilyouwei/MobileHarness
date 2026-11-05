import Foundation
import StorageCore

public actor CacheContainer {
    private nonisolated let admission = CacheAccess()
    public nonisolated func beginClosing() {
        admission.close()
        buffers.close()
    }
    public nonisolated let buffers: BufferCache
    public nonisolated var images: CacheNamespace { namespace("images") }
    public nonisolated func namespace(_ name: String) -> CacheNamespace { CacheNamespace(buffers: buffers, name: name) }
    private var audio: [String: AudioCache] = [:]
    private var shutdown: Task<Void, Never>?
    private var closing: [String: Task<Void, Never>] = [:]
    private let failures: StorageFailureReporter
    public init(failures: StorageFailureReporter = .init()) {
        self.failures = failures
        buffers = BufferCache(failures: failures)
    }
    public func stateSnapshot() async throws -> StorageStateSnapshot {
        try Task.checkCancellation()
        let value = buffers.runtimeStatistics()
        return StorageStateSnapshot(
            path: "storage.cache",
            runtime: [
                "entries": .count(value.entries), "retainedBytes": .count(value.retainedBytes),
                "maximumBytes": .count(value.maximumBytes), "audioScopes": .count(audio.count),
                "closingScopes": .count(closing.count), "closed": .flag(value.closed),
            ], units: ["runtime.retainedBytes": "bytes", "runtime.maximumBytes": "bytes"])
    }
    public func audioScope(_ id: String) throws -> AudioCache {
        do {
            try admission.check()
            guard shutdown == nil, closing[id] == nil else { throw StorageError.closed }
            if let existing = audio[id] { return existing }
            guard !id.isEmpty, id.utf8.count <= 256, audio.count < 64 else { throw StorageError.capacityExceeded }
            let cache = AudioCache(rootAccess: admission, failures: failures)
            audio[id] = cache
            return cache
        } catch {
            failures.report("cache", "audioScope", error)
            throw error
        }
    }
    public func closeAudioScope(_ id: String) async {
        if let existing = closing[id] {
            await existing.value
            return
        }
        guard let cache = audio[id] else { return }
        let task = Task { await cache.shutdown() }
        closing[id] = task
        await task.value
        audio[id] = nil
        closing[id] = nil
    }
    public func close() async {
        if let shutdown {
            await shutdown.value
            return
        }
        beginClosing()
        let caches = Array(audio.values)
        audio.removeAll()
        let task = Task { for cache in caches { await cache.shutdown() } }
        shutdown = task
        await task.value
    }
}
