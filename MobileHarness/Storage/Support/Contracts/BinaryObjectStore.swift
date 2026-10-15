import Foundation

public enum FileStorageError: Error, Sendable { case invalidPath, invalidFile, capacityExceeded, busy }
public struct BinaryObjectInfo: Sendable {
    public let bytes: Int
    public init(bytes: Int) { self.bytes = bytes }
}
public struct BinaryObjectPage: Sendable {
    public let keys: [String]
    public let next: String?
    public init(keys: [String], next: String?) {
        self.keys = keys
        self.next = next
    }
}
public struct BinaryPublicationError: Error, Sendable {
    public let publication: any Error
    public let cleanup: any Error
    public init(publication: any Error, cleanup: any Error) {
        self.publication = publication
        self.cleanup = cleanup
    }
}

/// Keys are confined relative names. Listing is bounded/best effort, not a cross-write snapshot.
public protocol BinaryObjectStore: Sendable {
    var durability: StorageDurability { get }
    func read(_ key: String, maximumBytes: Int) async throws -> Data?
    func info(_ key: String) async throws -> BinaryObjectInfo?
    func putIfAbsent(_ data: Data, key: String) async throws
    func remove(_ key: String) async throws
    func listObjects(cursor: String?, limit: Int) async throws -> BinaryObjectPage
    func closeListing(_ cursor: String) async
}
