import Foundation
import Synchronization

/// One application-owned, confined directory store. Publication markers travel with directories.
public actor LocalFileStore: BinaryObjectStore {
    public nonisolated let durability: StorageDurability = .persistent

    private let root: URL
    private var reservations: [String: Int64] = [:]
    private let objectProtection: DocumentFileProtection
    private let maximumBytes: Int64
    public init(
        root: URL, maximumBytes: Int64 = 32 * 1024 * 1024 * 1024, protection: DocumentFileProtection = .whileUnlocked
    ) throws {
        guard root.isFileURL, maximumBytes > 0 else { throw FileStorageError.invalidPath }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumBytes = maximumBytes
        objectProtection = protection
    }
    /// Derive a confined relative path using the same Foundation normalization for both URLs.
    /// Native directory enumeration may spell /var as /private/var.
    public nonisolated static func relativePath(of item: URL, within directory: URL) throws -> String {
        guard item.isFileURL, directory.isFileURL else { throw FileStorageError.invalidPath }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = item.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root) else { throw FileStorageError.invalidPath }
        let relative = String(path.dropFirst(root.count))
        guard !relative.isEmpty else { throw FileStorageError.invalidPath }
        return relative
    }
    private func location(_ relative: String) throws -> URL {
        let pieces = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") })
        else {
            throw FileStorageError.invalidPath
        }
        var next = root
        guard root.resolvingSymlinksInPath().path == root.path else { throw FileStorageError.invalidPath }
        for piece in pieces {
            next.appendPathComponent(String(piece))
            if FileManager.default.fileExists(atPath: next.path) {
                let values = try next.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw FileStorageError.invalidPath }
            }
        }
        return next
    }
    public func directory(_ relative: String, reserving bytes: Int64 = 0) throws -> URL {
        guard bytes >= 0, bytes <= maximumBytes else { throw FileStorageError.capacityExceeded }
        let url = try location(relative)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let free = try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
        let reserved = reservations.filter { $0.key != relative }.values.reduce(Int64(0), +)
        guard reserved <= maximumBytes - bytes, let free, free.int64Value > bytes + reserved else {
            throw FileStorageError.capacityExceeded
        }
        if bytes > 0 { reservations[relative] = bytes }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var support = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try support.setResourceValues(values)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        return url
    }
    public func read(_ relative: String, maximumBytes: Int) throws -> Data? {
        guard maximumBytes > 0, maximumBytes < Int.max else { throw FileStorageError.capacityExceeded }
        let url = try location(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw FileStorageError.invalidFile
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw FileStorageError.capacityExceeded }
        return data
    }
    public func publish(from temporary: String, to destination: String) throws {
        let source = try location(temporary)
        let target = try location(destination)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw FileStorageError.busy }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: target)
        reservations[temporary] = nil
    }
    public func remove(_ relative: String) throws {
        let url = try location(relative)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        reservations[relative] = nil
    }
    private final class ListingFault: Sendable { let error = Mutex<(any Error)?>(nil) }
    private struct Listing {
        let enumerator: FileManager.DirectoryEnumerator
        let fault: ListingFault
    }
    private var listings: [String: Listing] = [:]
    public func info(_ key: String) throws -> BinaryObjectInfo? {
        let url = try location(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { return nil }
        guard let bytes = values.fileSize else { throw FileStorageError.invalidFile }
        return BinaryObjectInfo(bytes: bytes)
    }
    public func putIfAbsent(_ data: Data, key: String) throws {
        guard data.count <= maximumBytes else { throw FileStorageError.capacityExceeded }
        let destination = try location(key)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw FileStorageError.busy }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent(".store-" + UUID().uuidString)
        do {
            #if os(iOS)
                try data.write(
                    to: temporary,
                    options: [
                        .atomic,
                        objectProtection == .afterFirstUnlock
                            ? .completeFileProtectionUntilFirstUserAuthentication : .completeFileProtection,
                    ])
            #else
                try data.write(to: temporary, options: .atomic)
            #endif
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.synchronize() } catch {
                let original = error
                do { try handle.close() } catch { throw BinaryPublicationError(publication: original, cleanup: error) }
                throw original
            }
            try handle.close()
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            let original = error
            do {
                if FileManager.default.fileExists(atPath: temporary.path) {
                    try FileManager.default.removeItem(at: temporary)
                }
            } catch { throw BinaryPublicationError(publication: original, cleanup: error) }
            throw original
        }
    }
    public func listObjects(cursor: String?, limit: Int) throws -> BinaryObjectPage {
        guard (1...128).contains(limit) else { throw FileStorageError.capacityExceeded }
        let token: String
        let listing: Listing
        if let cursor {
            guard let existing = listings.removeValue(forKey: cursor) else { throw FileStorageError.invalidPath }
            token = cursor
            listing = existing
        } else {
            guard listings.count < 4 else { throw FileStorageError.busy }
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fault = ListingFault()
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isRegularFileKey],
                    errorHandler: { _, error in
                        fault.error.withLock { $0 = error }
                        return false
                    })
            else { throw FileStorageError.invalidFile }
            token = UUID().uuidString
            listing = Listing(enumerator: enumerator, fault: fault)
        }
        var keys: [String] = []
        var exhausted = false
        for _ in 0..<limit {
            guard let url = listing.enumerator.nextObject() as? URL else {
                exhausted = true
                break
            }
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                keys.append(try Self.relativePath(of: url, within: root))
            }
        }
        if let error = listing.fault.error.withLock({ $0 }) { throw error }
        if !exhausted { listings[token] = listing }
        return BinaryObjectPage(keys: keys, next: exhausted ? nil : token)
    }
    public func closeListing(_ cursor: String) { listings[cursor] = nil }
}
