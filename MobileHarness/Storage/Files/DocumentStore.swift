import Foundation
import StorageCore

public enum DocumentFileProtection: Sendable, Equatable { case whileUnlocked, afterFirstUnlock }
public struct DocumentSnapshot<Value: Sendable>: Sendable {
    public let revision: UUID
    public let value: Value
    public init(revision: UUID, value: Value) {
        self.revision = revision
        self.value = value
    }
}

/// A revision-checked document. Backend choice determines whether successful writes survive restart.
public protocol DocumentStore<Value>: Sendable {
    associatedtype Value: Codable & Sendable
    var durability: StorageDurability { get }
    func load() async throws -> DocumentSnapshot<Value>?
    func refresh() async throws -> DocumentSnapshot<Value>?
    func invalidate() async
    func save(_ value: Value, expecting revision: UUID?) async throws -> DocumentSnapshot<Value>
    func replace(_ value: Value) async throws -> DocumentSnapshot<Value>
}
