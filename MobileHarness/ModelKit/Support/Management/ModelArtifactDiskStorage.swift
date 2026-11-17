import Foundation
import Synchronization

public actor ModelArtifactDiskStorage: ModelArtifactStorage {
    private struct Marker: Codable {
        let id: String
        let revision: String
        let files: [Member]
    }
    private struct Member: Codable {
        let path: String
        let bytes: Int64
    }
    public nonisolated static var defaultRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("MobileHarness/Models", isDirectory: true)
    }
    public nonisolated let root: URL
    public nonisolated var installedRoot: URL { root.appendingPathComponent("installed", isDirectory: true) }
    private var reservations: [String: Int64] = [:]
    public init(root: URL = ModelArtifactDiskStorage.defaultRoot) throws {
        guard root.isFileURL else { throw ModelArtifactError.storage }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }
    private struct TransferIndex: Codable {
        let version: Int
        let revision: UUID
        let value: [ModelArtifactTransferRecord]
    }
    public func restoreCatalog(defaults: ModelArtifactCatalog) async throws -> ModelArtifactCatalog {
        guard let data = try read("catalog.json", maximumBytes: 1_048_576) else { return defaults }
        let saved = try ModelArtifactCatalog.decode(data)
        let builtins = Set(defaults.packages.map(\.id))
        let combined = ModelArtifactCatalog(
            schemaVersion: 2,
            packages: defaults.packages + saved.packages.filter { !builtins.contains($0.id) })
        return try ModelArtifactCatalog.decode(JSONEncoder().encode(combined))
    }
    public func saveCatalog(_ catalog: ModelArtifactCatalog) async throws {
        let data = try JSONEncoder().encode(catalog)
        _ = try ModelArtifactCatalog.decode(data)
        _ = try directory("staging")
        try write(data, to: location("catalog.json"))
    }
    public func restoreTransfers() async throws -> [ModelArtifactTransferRecord] {
        guard let data = try read("transfers.json", maximumBytes: 262144) else { return [] }
        let index = try JSONDecoder().decode(TransferIndex.self, from: data)
        guard index.version == 1, index.value.count <= 10,
            Set(index.value.map(\.id)).count == index.value.count,
            index.value.allSatisfy({ ModelArtifactCatalog.validComponent($0.generation) })
        else { throw ModelArtifactError.storage }
        return index.value
    }
    public func saveTransfers(_ records: [ModelArtifactTransferRecord]) async throws {
        guard records.count <= 10 else { throw ModelArtifactError.busy }
        let data = try JSONEncoder().encode(TransferIndex(version: 1, revision: UUID(), value: records))
        guard data.count <= 262144 else { throw ModelArtifactError.storage }
        _ = try directory("staging")
        try write(data, to: location("transfers.json"))
    }
    public func installed(_ artifact: ModelArtifact) async throws -> Bool {
        let path = "installed/\(artifact.directory)/.installation.json"
        guard let data = try read(path, maximumBytes: 4 * 1024 * 1024) else { return false }
        let marker = try JSONDecoder().decode(Marker.self, from: data)
        guard marker.id == artifact.id, marker.revision == artifact.revision else {
            throw ModelArtifactError.incompatible
        }
        guard marker.files.count <= 16384, !marker.files.isEmpty
        else { return false }
        guard Set(artifact.requiredFiles).isSubset(of: Set(marker.files.map(\.path))) else { return false }
        let directory = try location("installed/\(artifact.directory)")
        var total: Int64 = 0
        for member in marker.files {
            guard member.bytes >= 0, member.bytes <= 32 * 1024 * 1024 * 1024 else { return false }
            total += member.bytes
            guard total <= 32 * 1024 * 1024 * 1024 else { return false }
            guard ModelArtifactCatalog.validInstalledPath(member.path) else { return false }
            let url = directory.appendingPathComponent(member.path)
            guard url.resolvingSymlinksInPath().path == url.path else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                values?.fileSize.map(Int64.init) == member.bytes
            else { return false }
        }

        return true
    }
    public func installedBytes(_ artifact: ModelArtifact) async throws -> Int64? {
        guard try await installed(artifact),
            let data = try read(
                "installed/\(artifact.directory)/.installation.json", maximumBytes: 4 * 1024 * 1024)
        else { return nil }
        return try JSONDecoder().decode(Marker.self, from: data).files.reduce(0) { $0 + $1.bytes }
    }
    public func stage(_ artifact: ModelArtifact, task: String) async throws -> URL {
        // A repeated download of the installed bundled revision requires explicit delete first.
        if try await installed(artifact) { throw ModelArtifactError.busy }
        return try directory(
            "staging/\(task)", reserving: artifact.downloadBytes + artifact.installedBytes)
    }
    public func publish(_ artifact: ModelArtifact, task: String) async throws {
        let stage = try directory("staging/\(task)")
        let members = try inventory(stage)
        guard !members.isEmpty, Set(artifact.requiredFiles).isSubset(of: Set(members.map(\.path))) else {
            throw ModelArtifactError.integrity
        }
        let marker = Marker(id: artifact.id, revision: artifact.revision, files: members)
        try write(JSONEncoder().encode(marker), to: stage.appendingPathComponent(".installation.json"))
        try publish(from: "staging/\(task)", to: "installed/\(artifact.directory)")
    }
    private final class EnumerationFailure: Sendable { let error = Mutex<(any Error)?>(nil) }
    private func inventory(_ stage: URL) throws -> [Member] {
        let failure = EnumerationFailure()
        guard
            let enumerator = FileManager.default.enumerator(
                at: stage, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                errorHandler: { _, error in
                    failure.error.withLock { $0 = error }
                    return false
                })
        else { throw ModelArtifactError.storage }
        var members: [Member] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw ModelArtifactError.integrity }
            if values.isRegularFile == true {
                let path = try relativePath(of: url, within: stage)
                if path == ".installation.json" { continue }
                guard ModelArtifactCatalog.validInstalledPath(path), members.count < 16384 else {
                    throw ModelArtifactError.integrity
                }
                guard let size = values.fileSize, size >= 0, Int64(size) <= 32 * 1024 * 1024 * 1024 - total else {
                    throw ModelArtifactError.integrity
                }
                total += Int64(size)
                members.append(Member(path: path, bytes: Int64(size)))
            }
        }
        if let error = failure.error.withLock({ $0 }) { throw error }
        return members.sorted { $0.path < $1.path }
    }
    public func discard(task: String) async throws { try remove("staging/\(task)") }
    public func remove(_ artifact: ModelArtifact) async throws {
        try remove("installed/\(artifact.directory)")
    }

    private func location(_ path: String) throws -> URL {
        guard ModelArtifactCatalog.validInstalledPath(path), root.resolvingSymlinksInPath().path == root.path else {
            throw ModelArtifactError.storage
        }
        var url = root
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
            guard url.resolvingSymlinksInPath().path == url.path else { throw ModelArtifactError.storage }
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw ModelArtifactError.storage
            }
        }
        return url
    }
    private func relativePath(of url: URL, within directory: URL) throws -> String {
        // Foundation enumeration can spell the same sandbox as /private/var or /var.
        let prefix = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(prefix) else { throw ModelArtifactError.integrity }
        return String(path.dropFirst(prefix.count))
    }
    private func directory(_ path: String, reserving bytes: Int64 = 0) throws -> URL {
        let url = try location(path)
        guard bytes >= 0, bytes <= 64 * 1024 * 1024 * 1024 else { throw ModelArtifactError.storage }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reserved = reservations.filter { $0.key != path }.values.reduce(Int64(0), +)
        guard reserved <= 64 * 1024 * 1024 * 1024 - bytes,
            bytes == 0 || reservations[path] != nil || reservations.count < 10
        else {
            throw ModelArtifactError.busy
        }
        let free = try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
        guard let free, free.int64Value > bytes + reserved else { throw ModelArtifactError.storage }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var root = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        if bytes > 0 { reservations[path] = bytes }
        return url
    }
    private func read(_ path: String, maximumBytes: Int) throws -> Data? {
        let url = try location(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ModelArtifactError.storage
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ModelArtifactError.storage }
        return data
    }
    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: url, options: .atomic)
        #endif
    }
    private func publish(from source: String, to target: String) throws {
        let sourceURL = try location(source)
        let targetURL = try location(target)
        guard !FileManager.default.fileExists(atPath: targetURL.path) else { throw ModelArtifactError.busy }
        _ = try directory("installed")
        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
        reservations[source] = nil
    }
    private func remove(_ path: String) throws {
        let url = try location(path)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        reservations[path] = nil
    }
}
