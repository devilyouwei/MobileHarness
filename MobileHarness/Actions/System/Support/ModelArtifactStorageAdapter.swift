import Foundation
import ModelKitRuntime
import Storage

actor ModelArtifactStorageAdapter: ModelArtifactStorage {
    private struct Marker: Codable {
        let id: String
        let revision: String
        let files: [Member]
    }
    private struct Member: Codable {
        let path: String
        let bytes: Int64
    }
    private let files: LocalFileStore
    private let index: (any DocumentRepository<[ModelArtifactTransferRecord]>)
    public init(root: URL) throws {
        files = try LocalFileStore(root: root)
        index = try LocalDocumentStore(
            url: root.appendingPathComponent("transfers.json"), maximumBytes: 262144,
            protection: .afterFirstUnlock)
    }
    public func restoreTransfers() async throws -> [ModelArtifactTransferRecord] {
        try await index.load()?.value ?? []
    }
    public func saveTransfers(_ records: [ModelArtifactTransferRecord]) async throws {
        guard records.count <= 10 else { throw ModelArtifactError.busy }
        try await index.replace(records)
    }
    public func installed(_ artifact: ModelArtifact) async throws -> Bool {
        let path = "installed/\(artifact.directory)/.installation.json"
        guard let data = try await files.read(path, maximumBytes: 4 * 1024 * 1024) else { return false }
        var marker = try JSONDecoder().decode(Marker.self, from: data)
        guard marker.id == artifact.id, marker.revision == artifact.revision else {
            throw ModelArtifactError.incompatible
        }
        guard marker.files.count <= 16384, !marker.files.isEmpty
        else { return false }
        var repairingLegacyPaths = false
        if !Set(artifact.requiredFiles).isSubset(of: Set(marker.files.map(\.path))) {
            // The former /var vs /private/var length subtraction prepended the staging UUID's
            // last seven hex digits to every receipt path. Repair only this exact known shape.
            let components = marker.files.map { $0.path.split(separator: "/", omittingEmptySubsequences: false) }
            guard let prefix = components.first?.first, prefix.count == 7,
                prefix.allSatisfy({ "0123456789ABCDEF".contains($0) }),
                components.allSatisfy({ $0.count > 1 && $0.first == prefix })
            else { return false }
            let remapped = zip(marker.files, components).map { member, path in
                Member(path: path.dropFirst().joined(separator: "/"), bytes: member.bytes)
            }
            guard Set(artifact.requiredFiles).isSubset(of: Set(remapped.map(\.path))) else { return false }
            marker = Marker(id: marker.id, revision: marker.revision, files: remapped)
            repairingLegacyPaths = true
        }
        let directory = try await files.directory("installed/\(artifact.directory)")
        var total: Int64 = 0
        for member in marker.files {
            guard member.bytes >= 0, member.bytes <= 32 * 1024 * 1024 * 1024 else { return false }
            total += member.bytes
            guard total <= 32 * 1024 * 1024 * 1024 else { return false }
            guard ModelArtifactCatalog.validInstalledPath(member.path) else { return false }
            let url = directory.appendingPathComponent(member.path)
            guard url.resolvingSymlinksInPath() == url else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                values?.fileSize.map(Int64.init) == member.bytes
            else { return false }
        }
        if repairingLegacyPaths {
            try JSONEncoder().encode(marker).write(
                to: directory.appendingPathComponent(".installation.json"), options: .atomic)
        }
        return true
    }
    public func installedBytes(_ artifact: ModelArtifact) async throws -> Int64? {
        guard try await installed(artifact),
            let data = try await files.read(
                "installed/\(artifact.directory)/.installation.json", maximumBytes: 4 * 1024 * 1024)
        else { return nil }
        return try JSONDecoder().decode(Marker.self, from: data).files.reduce(0) { $0 + $1.bytes }
    }
    public func stage(_ artifact: ModelArtifact, task: String) async throws -> URL {
        // A repeated download of the installed bundled revision requires explicit delete first.
        if try await installed(artifact) { throw ModelArtifactError.busy }
        return try await files.directory(
            "staging/\(task)", reserving: artifact.downloadBytes + artifact.installedBytes)
    }
    public func publish(_ artifact: ModelArtifact, task: String) async throws {
        let stage = try await files.directory("staging/\(task)")
        let marker = Marker(id: artifact.id, revision: artifact.revision, files: try inventory(stage))
        try JSONEncoder().encode(marker).write(to: stage.appendingPathComponent(".installation.json"), options: .atomic)
        try await files.publish(from: "staging/\(task)", to: "installed/\(artifact.directory)")
    }
    private func inventory(_ stage: URL) throws -> [Member] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: stage, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        else { throw ModelArtifactError.storage }
        var members: [Member] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw ModelArtifactError.integrity }
            if values.isRegularFile == true {
                let path = try LocalFileStore.relativePath(of: url, within: stage)
                guard ModelArtifactCatalog.validInstalledPath(path), members.count < 16384 else {
                    throw ModelArtifactError.integrity
                }
                members.append(Member(path: path, bytes: Int64(values.fileSize ?? 0)))
            }
        }
        return members.sorted { $0.path < $1.path }
    }
    public func discard(task: String) async throws { try await files.remove("staging/\(task)") }
    public func remove(_ artifact: ModelArtifact) async throws {
        try await files.remove("installed/\(artifact.directory)")
    }
}
