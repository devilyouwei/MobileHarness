import Foundation

public enum FileStorageError: Error, Sendable { case invalidPath, invalidFile, capacityExceeded, busy }

/// One application-owned, confined directory store. Publication markers travel with directories.
public actor LocalFileStore {
    private let root: URL
    private var reservations: [String: Int64] = [:]
    private let maximumBytes: Int64
    public init(root: URL, maximumBytes: Int64 = 32 * 1024 * 1024 * 1024) throws {
        guard root.isFileURL, maximumBytes > 0 else { throw FileStorageError.invalidPath }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumBytes = maximumBytes
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
}
