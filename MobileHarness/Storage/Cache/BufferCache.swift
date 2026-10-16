import Foundation
import StorageCore
import Synchronization

/// Immutable bytes. Ingress from Data shares its value storage; mutation uses Data's copy-on-write.
public final class CacheBuffer: Sendable, Equatable {
    public static func == (lhs: CacheBuffer, rhs: CacheBuffer) -> Bool { lhs.bytes == rhs.bytes }
    var data: Data { bytes }
    public let id = UUID()
    private let bytes: Data
    public var count: Int { bytes.count }
    public init(_ bytes: Data) { self.bytes = bytes }
    public func withUnsafeBytes<Result: Sendable>(_ body: @Sendable (UnsafeRawBufferPointer) throws -> Result) rethrows
        -> Result
    {
        try bytes.withUnsafeBytes(body)
    }
}
public final class CacheLease: Sendable {
    public let bufferID: UUID
    private struct State { var buffer: CacheBuffer? }
    private let state: Mutex<State>
    private let access: CacheAccess
    private let onRelease: @Sendable () -> Void
    fileprivate init(_ buffer: CacheBuffer, access: CacheAccess, onRelease: @escaping @Sendable () -> Void) {
        bufferID = buffer.id
        state = Mutex(State(buffer: buffer))
        self.access = access
        self.onRelease = onRelease
    }
    public func withUnsafeBytes<Result: Sendable>(_ body: @Sendable (UnsafeRawBufferPointer) throws -> Result) throws
        -> Result
    {
        try state.withLock { state in
            try access.check()
            guard let buffer = state.buffer else { throw StorageError.closed }
            return try buffer.withUnsafeBytes(body)
        }
    }
    public func release() {
        let released = state.withLock { value in
            let present = value.buffer != nil
            value.buffer = nil
            return present
        }
        if released { onRelease() }
    }
    deinit { release() }
}
final class CacheAccess: Sendable {
    private let closed = Mutex(false)
    func check() throws { try closed.withLock { if $0 { throw StorageError.closed } } }
    func close() { closed.withLock { $0 = true } }
}
/// All namespaces share one bounded budget; removal never invalidates a live lease's memory.
public final class BufferCache: Sendable {
    private struct Key: Hashable {
        let namespace: String
        let name: String
    }
    private struct Retained {
        let buffer: CacheBuffer
        var keys: Int
        var leases: Int
    }
    private struct State {
        var values: [Key: UUID] = [:]
        var retained: [UUID: Retained] = [:]
        var bytes = 0
        var closed = false
    }
    private let state = Mutex(State())
    private let access = CacheAccess()
    private let capacity: Int
    private let maximumBytes: Int
    public init(capacity: Int = 256, maximumBytes: Int = 64 * 1024 * 1024) {
        self.capacity = capacity
        self.maximumBytes = maximumBytes
    }
    public func put(_ buffer: CacheBuffer, key: String, namespace: String = "images") throws {
        guard !key.isEmpty, key.utf8.count <= 256, !namespace.isEmpty, namespace.utf8.count <= 256 else {
            throw StorageError.forbidden
        }
        try state.withLock { state in
            guard !state.closed else { throw StorageError.closed }
            let key = Key(namespace: namespace, name: key)
            guard state.values[key] == nil else { throw StorageError.duplicate }
            guard state.values.count < capacity else { throw StorageError.capacityExceeded }
            if var retained = state.retained[buffer.id] {
                retained.keys += 1
                state.retained[buffer.id] = retained
            } else {
                guard state.retained.count < capacity, buffer.count <= maximumBytes - state.bytes else {
                    throw StorageError.capacityExceeded
                }
                state.retained[buffer.id] = Retained(buffer: buffer, keys: 1, leases: 0)
                state.bytes += buffer.count
            }
            state.values[key] = buffer.id
        }
    }
    public func get(_ key: String, namespace: String = "images") throws -> CacheLease {
        try state.withLock { state in
            guard !state.closed else { throw StorageError.closed }
            guard let id = state.values[Key(namespace: namespace, name: key)], var retained = state.retained[id] else {
                throw StorageError.missing
            }
            guard retained.leases < 256 else { throw StorageError.capacityExceeded }
            retained.leases += 1
            state.retained[id] = retained
            return CacheLease(retained.buffer, access: access) { [weak self] in self?.release(id) }
        }
    }
    public func remove(_ key: String, namespace: String = "images") throws {
        try state.withLock { state in
            guard !state.closed else { throw StorageError.closed }
            if let id = state.values.removeValue(forKey: Key(namespace: namespace, name: key)),
                var retained = state.retained[id]
            {
                retained.keys -= 1
                state.retained[id] = retained
                reap(id, state: &state)
            }
        }
    }
    private func release(_ id: UUID) {
        state.withLock { state in
            guard var retained = state.retained[id] else { return }
            retained.leases -= 1
            state.retained[id] = retained
            reap(id, state: &state)
        }
    }
    private func reap(_ id: UUID, state: inout State) {
        if let retained = state.retained[id], retained.keys == 0, retained.leases == 0 {
            state.bytes -= retained.buffer.count
            state.retained[id] = nil
        }
    }
    public func close() {
        state.withLock {
            $0.closed = true
            $0.values.removeAll()
            $0.retained.removeAll()
            $0.bytes = 0
        }
        access.close()
    }
}
public struct CacheNamespace: Sendable {
    private let buffers: BufferCache
    private let name: String
    fileprivate init(buffers: BufferCache, name: String) {
        self.buffers = buffers
        self.name = name
    }
    public func put(_ buffer: CacheBuffer, key: String) throws { try buffers.put(buffer, key: key, namespace: name) }
    public func get(_ key: String) throws -> CacheLease { try buffers.get(key, namespace: name) }
    public func remove(_ key: String) throws { try buffers.remove(key, namespace: name) }
}
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
    public init() { buffers = BufferCache() }
    public func audioScope(_ id: String) throws -> AudioCache {
        try admission.check()
        guard shutdown == nil, closing[id] == nil else { throw StorageError.closed }
        if let existing = audio[id] { return existing }
        guard !id.isEmpty, id.utf8.count <= 256, audio.count < 64 else { throw StorageError.capacityExceeded }
        let cache = AudioCache(rootAccess: admission)
        audio[id] = cache
        return cache
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
