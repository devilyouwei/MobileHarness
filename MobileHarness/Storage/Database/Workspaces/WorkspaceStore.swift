import Foundation
import StorageCore
import StorageFiles

/// Coordinates the authoritative current directory and its recoverable SQL index.
public actor WorkspaceStore {
    private let disk: DiskFileStore
    private let index: any WorkspaceRepository
    private let gate = StorageOperationGate()
    public init(disk: DiskFileStore, index: any WorkspaceRepository) {
        self.disk = disk
        self.index = index
    }
    public func read(_ id: WorkspaceID) async throws -> (WorkspaceSummary, [String: String])? {
        try await gate.withAccess { [self] in
            guard var info = try await index.workspace(id), !info.deleting else { return nil }
            let files = try await readFiles(id)
            if !info.needsIndexRecovery && info.files.contains(where: { files[$0.path] == nil }) {
                throw FileStorageError.invalidFile
            }
            let actual = Self.fileIndex(files)
            guard let checked = try await index.workspace(id), !checked.deleting else {
                throw RecordStorageError.conflict
            }
            if checked.files != info.files && actual != checked.files { throw RecordStorageError.busy }
            info = checked
            if actual != info.files {
                let lease = UUID()
                try await index.claim(id, expecting: info.revision, lease: lease)
                do {
                    info = .init(
                        id: id, title: info.title, entry: info.entry, revision: info.revision, hasDraft: true,
                        deleting: false, files: actual)
                    try await index.commit(info, lease: lease)
                } catch {
                    let primary = error
                    do { try await index.release(id, lease: lease) } catch {
                        throw BinaryPublicationError(publication: primary, cleanup: error)
                    }
                    throw primary
                }
            }
            return (info, files)
        }
    }
    public func write(
        _ id: WorkspaceID, expecting: UUID?, title: String, entry: String, files: [String: String], published: Bool
    ) async throws -> WorkspaceSummary {
        try await gate.withAccess { [self] in
            let wasPresent = try await index.workspace(id) != nil
            let lease = UUID()
            try await index.claim(id, expecting: expecting, lease: lease)
            do {
                if !wasPresent { try await disk.remove(id.rawValue) }
                let previous = try await readFiles(id, creating: true)
                // Each replacement is atomic. A partially committed collection is a draft after failure.
                for (path, text) in files.sorted(by: { $0.key < $1.key }) where previous[path] != text {
                    try Task.checkCancellation()
                    try await disk.replace(Data(text.utf8), key: id.rawValue + "/" + path)
                }
                for path in previous.keys where files[path] == nil { try await disk.remove(id.rawValue + "/" + path) }
                let value = WorkspaceSummary(
                    id: id, title: title, entry: entry, revision: published ? UUID() : expecting, hasDraft: !published,
                    deleting: false, files: Self.fileIndex(files))
                try await index.commit(value, lease: lease)
                return value
            } catch {
                let primary = error
                do { try await index.release(id, lease: lease) } catch {
                    throw BinaryPublicationError(publication: primary, cleanup: error)
                }
                throw primary
            }
        }
    }
    private func readFiles(_ id: WorkspaceID, creating: Bool = false) async throws -> [String: String] {
        if creating { _ = try await disk.directory(id.rawValue) }
        return try await disk.textFiles(in: id.rawValue)
    }
    private static func fileIndex(_ files: [String: String]) -> [WorkspaceFile] {
        files.sorted { $0.key < $1.key }.map {
            let data = Data($0.value.utf8)
            return .init(
                path: $0.key, bytes: data.count,
                fingerprint: ContentFingerprint.digest(data).map { String(format: "%02x", $0) }.joined())
        }
    }
}
