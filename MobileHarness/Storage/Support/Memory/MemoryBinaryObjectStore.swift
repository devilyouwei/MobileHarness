import Foundation

public actor MemoryBinaryObjectStore: BinaryObjectStore {
    public nonisolated let durability: StorageDurability = .memory

    private var objects: [String: Data] = [:]
    private var listings: [String: [String]] = [:]
    private let maximumBytes: Int
    private let capacity: Int
    public init(capacity: Int = 256, maximumBytes: Int = 64 * 1024 * 1024) throws {
        guard capacity > 0, maximumBytes > 0 else { throw FileStorageError.capacityExceeded }
        self.capacity = capacity
        self.maximumBytes = maximumBytes
    }
    private func validate(_ key: String) throws {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw FileStorageError.invalidPath
        }
    }
    public func read(_ key: String, maximumBytes: Int) throws -> Data? {
        try validate(key)
        guard maximumBytes > 0 else { throw FileStorageError.capacityExceeded }
        guard let data = objects[key] else { return nil }
        guard data.count <= maximumBytes else { throw FileStorageError.capacityExceeded }
        return data
    }
    public func info(_ key: String) throws -> BinaryObjectInfo? {
        try validate(key)
        return objects[key].map { BinaryObjectInfo(bytes: $0.count) }
    }
    public func putIfAbsent(_ data: Data, key: String) throws {
        try validate(key)
        guard objects[key] == nil else { throw FileStorageError.busy }
        guard objects.count < capacity, data.count <= maximumBytes,
            objects.values.reduce(0, { $0 + $1.count }) <= maximumBytes - data.count
        else { throw FileStorageError.capacityExceeded }
        objects[key] = data
    }
    public func remove(_ key: String) throws {
        try validate(key)
        objects[key] = nil
    }
    public func listObjects(cursor: String?, limit: Int) throws -> BinaryObjectPage {
        guard (1...128).contains(limit) else { throw FileStorageError.capacityExceeded }
        let token: String
        var keys: [String]
        if let cursor {
            guard let existing = listings.removeValue(forKey: cursor) else { throw FileStorageError.invalidPath }
            token = cursor
            keys = existing
        } else {
            guard listings.count < 4 else { throw FileStorageError.busy }
            token = UUID().uuidString
            keys = objects.keys.sorted()
        }
        let page = Array(keys.prefix(limit))
        keys.removeFirst(page.count)
        if !keys.isEmpty { listings[token] = keys }
        return BinaryObjectPage(keys: page, next: keys.isEmpty ? nil : token)
    }
    public func closeListing(_ cursor: String) { listings[cursor] = nil }
}
