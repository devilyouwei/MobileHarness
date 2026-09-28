import Foundation

public enum DocumentStorageError: Error, Equatable, Sendable {
    case invalidConfiguration, capacityExceeded, unsupportedVersion, conflict, invalidFile
}

public struct DocumentSnapshot<Value: Sendable>: Sendable {
    public let revision: UUID
    public let value: Value
}

// Serializes compare-and-replace across store instances within this process.
private enum DocumentFileAccess {
    static let lock = NSLock()
}

/// A bounded, write-through cache for one durable JSON document.
/// App owns the trusted sandbox URL and payload schema. Cross-process writers are unsupported.
public actor LocalDocumentStore<Value: Codable & Sendable> {
    private struct Envelope: Codable {
        let version: Int
        let revision: UUID
        let value: Value
    }
    private let url: URL
    private let maximumBytes: Int
    private var cached: DocumentSnapshot<Value>?
    private var loaded = false

    public init(url: URL, maximumBytes: Int = 65_536) throws {
        guard url.isFileURL, maximumBytes > 0, maximumBytes < Int.max else {
            throw DocumentStorageError.invalidConfiguration
        }
        self.url = url
        self.maximumBytes = maximumBytes
    }

    public func load() throws -> DocumentSnapshot<Value>? {
        if loaded { return cached }
        return try refresh()
    }

    /// Disk wins on explicit refresh; a failed read never replaces the last valid cache.
    public func refresh() throws -> DocumentSnapshot<Value>? {
        let result = try DocumentFileAccess.lock.withLock { try readDisk() }
        cached = result
        loaded = true
        return result
    }

    public func invalidate() {
        cached = nil
        loaded = false
    }

    /// nil expects an absent file. Stale revisions fail instead of overwriting another writer.
    @discardableResult
    public func save(_ value: Value, expecting revision: UUID?) throws -> DocumentSnapshot<Value> {
        let next = DocumentSnapshot(revision: UUID(), value: value)
        let data = try JSONEncoder().encode(Envelope(version: 1, revision: next.revision, value: value))
        guard data.count <= maximumBytes else { throw DocumentStorageError.capacityExceeded }
        try DocumentFileAccess.lock.withLock {
            guard try readDisk()?.revision == revision else { throw DocumentStorageError.conflict }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            #if os(iOS)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
                try data.write(to: url, options: .atomic)
            #endif
        }
        cached = next
        loaded = true
        return next
    }

    private func readDisk() throws -> DocumentSnapshot<Value>? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw DocumentStorageError.invalidFile
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { throw DocumentStorageError.capacityExceeded }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1 else { throw DocumentStorageError.unsupportedVersion }
            return DocumentSnapshot(revision: envelope.revision, value: envelope.value)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }
}
