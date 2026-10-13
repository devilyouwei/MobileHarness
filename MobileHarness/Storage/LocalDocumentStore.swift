import Foundation

public enum DocumentStorageError: Error, Equatable, Sendable {
    case invalidConfiguration, capacityExceeded, unsupportedVersion, conflict, invalidFile
}

public enum DocumentFileProtection: Sendable { case whileUnlocked, afterFirstUnlock }

public struct DocumentSnapshot<Value: Sendable>: Sendable {
    public let revision: UUID
    public let value: Value
}

// Serializes compare-and-replace across store instances within this process.
private enum DocumentFileAccess {
    private final class Entry: @unchecked Sendable {
        weak var lock: NSLock?
        init(_ lock: NSLock) { self.lock = lock }
    }
    // Mutable registry is protected by its own short-lived lock; file I/O uses a distinct lock.
    private final class Registry: @unchecked Sendable {
        let gate = NSLock()
        var entries: [String: Entry] = [:]
        func lock(for key: String) -> NSLock {
            gate.withLock {
                if let existing = entries[key]?.lock { return existing }
                if entries.count >= 256 { entries = entries.filter { $0.value.lock != nil } }
                let lock = NSLock()
                entries[key] = Entry(lock)
                return lock
            }
        }
    }
    private static let registry = Registry()
    static func withLock<Result>(for url: URL, _ body: () throws -> Result) rethrows -> Result {
        let lock = registry.lock(for: url.standardizedFileURL.path)
        return try lock.withLock(body)
    }
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
    private let protection: DocumentFileProtection
    private var cached: DocumentSnapshot<Value>?
    private var loaded = false

    public init(
        url: URL, maximumBytes: Int = 65_536, protection: DocumentFileProtection = .whileUnlocked
    ) throws {
        guard url.isFileURL, maximumBytes > 0, maximumBytes < Int.max else {
            throw DocumentStorageError.invalidConfiguration
        }
        self.url = url
        self.maximumBytes = maximumBytes
        self.protection = protection
    }

    public func load() throws -> DocumentSnapshot<Value>? {
        if loaded { return cached }
        return try refresh()
    }

    /// Disk wins on explicit refresh; a failed read never replaces the last valid cache.
    public func refresh() throws -> DocumentSnapshot<Value>? {
        let result = try DocumentFileAccess.withLock(for: url) { try readDisk() }
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
        try DocumentFileAccess.withLock(for: url) {
            guard try readDisk()?.revision == revision else { throw DocumentStorageError.conflict }
            try writeDisk(data)
        }
        cached = next
        loaded = true
        return next
    }

    /// Explicit last-writer-wins replacement for an authoritative single-owner snapshot.
    /// Read/modify/write consumers must continue to use save(_:expecting:).
    @discardableResult
    public func replace(_ value: Value) throws -> DocumentSnapshot<Value> {
        let next = DocumentSnapshot(revision: UUID(), value: value)
        let data = try JSONEncoder().encode(Envelope(version: 1, revision: next.revision, value: value))
        guard data.count <= maximumBytes else { throw DocumentStorageError.capacityExceeded }
        try DocumentFileAccess.withLock(for: url) { try writeDisk(data) }
        cached = next
        loaded = true
        return next
    }
    private func writeDisk(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        #if os(iOS)
            let protectionOption: Data.WritingOptions =
                protection == .afterFirstUnlock
                ? .completeFileProtectionUntilFirstUserAuthentication : .completeFileProtection
            try data.write(to: url, options: [.atomic, protectionOption])
        #else
            try data.write(to: url, options: .atomic)
        #endif
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
