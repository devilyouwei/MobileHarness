import Foundation
import StorageCore

/// Process-local implementation of the same document/version contract; never claims durability.
public actor MemoryDocumentStore<Value: Codable & Sendable>: DocumentStore {
    public nonisolated let durability: StorageDurability = .memory

    private var snapshot: DocumentSnapshot<Value>?
    private let maximumBytes: Int
    public init(maximumBytes: Int = 65_536) throws {
        guard maximumBytes > 0 else { throw DocumentStorageError.invalidConfiguration }
        self.maximumBytes = maximumBytes
    }
    public func load() -> DocumentSnapshot<Value>? { snapshot }
    public func refresh() -> DocumentSnapshot<Value>? { snapshot }
    public func invalidate() {}
    public func save(_ value: Value, expecting revision: UUID?) throws -> DocumentSnapshot<Value> {
        guard snapshot?.revision == revision else { throw DocumentStorageError.conflict }
        return try replace(value)
    }
    public func replace(_ value: Value) throws -> DocumentSnapshot<Value> {
        guard try JSONEncoder().encode(value).count <= maximumBytes else { throw DocumentStorageError.capacityExceeded }
        let next = DocumentSnapshot(revision: UUID(), value: value)
        snapshot = next
        return next
    }
}
