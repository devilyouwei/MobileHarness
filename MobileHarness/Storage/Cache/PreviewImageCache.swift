import Foundation
import StorageCore
import Synchronization

/// Ordered temporary bytes; consumers supply pin policy. No filesystem or model dependency.
public final class PreviewImageCache: Sendable {
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let bytes: Int
    }
    private struct State {
        var entries: [Entry] = []
        var pins: Set<String> = []
        var reservation: String?
        var closed = false
    }
    private let state = Mutex(State())
    private let namespace: CacheNamespace
    public let maximumCount: Int
    public let maximumBytes: Int
    public let maximumImageBytes: Int
    public init(namespace: CacheNamespace, maximumCount: Int = 8, maximumBytes: Int = 32 * 1024 * 1024,
                maximumImageBytes: Int = 4 * 1024 * 1024) {
        self.namespace = namespace
        self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes
        self.maximumImageBytes = maximumImageBytes
    }
    public var entries: [Entry] { state.withLock { $0.entries } }
    public func protect(_ ids: Set<String>) { state.withLock { $0.pins = ids } }
    /// One capture reservation; evict only unpinned oldest entries before admitting a shutter.
    public func reserve() throws -> String {
        try state.withLock { value in
            guard !value.closed else { throw StorageError.closed }
            guard value.reservation == nil else { throw StorageError.capacityExceeded }
            guard maximumCount > 0, maximumBytes >= maximumImageBytes, maximumImageBytes > 0 else {
                throw StorageError.capacityExceeded
            }
            var candidates = value.entries
            var removed: [String] = []
            while candidates.count >= maximumCount || candidates.reduce(0, { $0 + $1.bytes }) + maximumImageBytes > maximumBytes {
                guard let index = candidates.firstIndex(where: { !value.pins.contains($0.id) }) else {
                    throw StorageError.capacityExceeded
                }
                removed.append(candidates.remove(at: index).id)
            }
            for id in removed { try namespace.remove(id) }
            value.entries = candidates
            let id = "preview_" + UUID().uuidString
            value.reservation = id
            return id
        }
    }
    public func cancel(_ reservation: String) { state.withLock { if $0.reservation == reservation { $0.reservation = nil } } }
    public func publish(_ data: Data, reservation: String) throws {
        try state.withLock { value in
            guard !value.closed else { throw StorageError.closed }
            guard value.reservation == reservation else { throw StorageError.missing }
            guard !data.isEmpty, data.count <= maximumImageBytes else { throw StorageError.capacityExceeded }
            try namespace.put(CacheBuffer(data), key: reservation)
            value.entries.append(.init(id: reservation, bytes: data.count))
            value.reservation = nil
        }
    }
    public func read(_ id: String) throws -> Data {
        try state.withLock { value in
            guard !value.closed else { throw StorageError.closed }
            guard value.entries.contains(where: { $0.id == id }) else { throw StorageError.missing }
            let lease = try namespace.get(id)
            defer { lease.release() }
            return try lease.withUnsafeBytes { Data($0) }
        }
    }
    public func remove(_ id: String) throws {
        try state.withLock { value in
            guard !value.closed else { throw StorageError.closed }
            guard value.entries.contains(where: { $0.id == id }) else { throw StorageError.missing }
            try namespace.remove(id)
            value.entries.removeAll { $0.id == id }
            value.pins.remove(id)
        }
    }
    public func close() throws {
        try state.withLock { value in
            guard !value.closed else { return }
            for entry in value.entries { try namespace.remove(entry.id) }
            value = State(closed: true)
        }
    }
}
