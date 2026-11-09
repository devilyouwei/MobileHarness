import Foundation
import StorageCore
import Synchronization

/// A session-scoped ordered image store. Consumers own selection and disposition policy.
public final class PreviewImageCache: Sendable {
    public enum Disposition: String, Codable, Sendable { case pending, saved }
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let bytes: Int
        public let capturedAt: Date
        public let width: Int
        public let height: Int
        public var disposition: Disposition = .pending
        public var mediaID: String?
    }
    private struct State {
        var scope: String?
        var entries: [Entry] = []
        var originals: [String: Data] = [:]
        var analysis: [String: Data] = [:]
        var reservation: String?
        var closed = false
    }
    private let state = Mutex(State())
    public let maximumCount: Int
    public let maximumBytes: Int
    public let maximumImageBytes: Int
    public init(maximumCount: Int = 20, maximumBytes: Int = 112 * 1024 * 1024, maximumImageBytes: Int = 4 * 1024 * 1024)
    {
        self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes
        self.maximumImageBytes = maximumImageBytes
    }
    public var scope: String? { state.withLock { $0.scope } }
    public var entries: [Entry] { state.withLock { $0.entries } }
    public var retainedBytes: Int { state.withLock { Self.bytes($0) } }
    private static func bytes(_ value: State) -> Int {
        value.originals.values.reduce(0) { $0 + $1.count } + value.analysis.values.reduce(0) { $0 + $1.count }
    }
    public func open(_ scope: String) throws {
        try state.withLock {
            guard !$0.closed else { throw StorageError.closed }
            guard $0.scope == nil, !scope.isEmpty else { throw StorageError.forbidden }
            $0 = State(scope: scope)
        }
    }
    public func endSession() { state.withLock { $0 = State(closed: $0.closed) } }
    public func reserve(id: String) throws -> String {
        try state.withLock { value in
            guard !value.closed, value.scope != nil else { throw StorageError.closed }
            guard !id.isEmpty, id.utf8.count <= 64 else { throw StorageError.forbidden }
            guard value.originals[id] == nil else { throw StorageError.duplicate }
            guard value.reservation == nil, (1...20).contains(maximumCount), maximumImageBytes > 0,
                maximumImageBytes <= 4 * 1024 * 1024, maximumBytes <= 112 * 1024 * 1024,
                Self.bytes(value) + maximumImageBytes <= maximumBytes
            else { throw StorageError.capacityExceeded }
            value.reservation = id
            return id
        }
    }
    public func cancel(_ id: String) { state.withLock { if $0.reservation == id { $0.reservation = nil } } }
    /// Commit first, then retire the oldest entry. A failed reservation never evicts existing photos.
    @discardableResult public func publish(_ data: Data, reservation id: String, width: Int = 1, height: Int = 1) throws
        -> String?
    {
        try state.withLock { value in
            guard !value.closed, value.scope != nil else { throw StorageError.closed }
            guard value.reservation == id else { throw StorageError.missing }
            guard !data.isEmpty, data.count <= maximumImageBytes, width > 0, height > 0 else {
                throw StorageError.capacityExceeded
            }
            value.originals[id] = data
            value.entries.append(.init(id: id, bytes: data.count, capturedAt: Date(), width: width, height: height))
            value.reservation = nil
            guard value.entries.count > maximumCount else { return nil }
            let removed = value.entries.removeFirst().id
            value.originals[removed] = nil
            value.analysis[removed] = nil
            return removed
        }
    }
    public func read(_ id: String) throws -> Data {
        try state.withLock {
            guard !$0.closed, $0.scope != nil else { throw StorageError.closed }
            guard let data = $0.originals[id] else { throw StorageError.missing }
            return data
        }
    }
    public func mark(_ id: String, disposition: Disposition, mediaID: String? = nil) throws {
        try state.withLock {
            guard !$0.closed, $0.scope != nil else { throw StorageError.closed }
            guard let index = $0.entries.firstIndex(where: { $0.id == id }) else { throw StorageError.missing }
            $0.entries[index].disposition = disposition
            $0.entries[index].mediaID = mediaID
        }
    }
    public func storeAnalysis(_ data: Data, id: String) throws {
        try state.withLock {
            guard !$0.closed, $0.originals[id] != nil else { throw StorageError.missing }
            guard !data.isEmpty, data.count <= 1024 * 1024,
                Self.bytes($0) - ($0.analysis[id]?.count ?? 0) + data.count
                    + ($0.reservation == nil ? 0 : maximumImageBytes) <= maximumBytes
            else { throw StorageError.capacityExceeded }
            $0.analysis[id] = data
        }
    }
    public func removeAnalysis(_ id: String) { state.withLock { $0.analysis[id] = nil } }
    public func close() { state.withLock { $0 = State(closed: true) } }
}
