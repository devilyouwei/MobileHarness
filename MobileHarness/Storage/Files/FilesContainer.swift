import Foundation
import StorageCore
import Synchronization

public final class FileAccess: Sendable {
    private let closed = Mutex(false)
    let failures: StorageFailureReporter
    public init(failures: StorageFailureReporter = .init()) { self.failures = failures }
    public func check() throws { try closed.withLock { if $0 { throw StorageError.closed } } }
    func close() { closed.withLock { $0 = true } }
}
public final class FilesContainer: Sendable {
    private struct State {
        var closed = false
        var shutdown: Task<Void, Never>?
        var files: [String: DiskFileStore] = [:]
        var fileProtection: [String: DocumentFileProtection] = [:]
        var documentConfiguration: [String: (Int, DocumentFileProtection)] = [:]
        var documents: [String: any Sendable] = [:]
        var closers: [@Sendable () async -> Void] = []
    }
    private let id = UUID()
    private let state = Mutex(State())
    private let access: FileAccess
    private let failures: StorageFailureReporter
    public let settings: FileNamespace
    public let photos: FileNamespace
    public let models: FileNamespace
    public init(settings: URL, photos: URL, models: URL, failures: StorageFailureReporter = .init()) {
        self.failures = failures
        access = FileAccess(failures: failures)
        self.settings = FileNamespace(root: settings, owner: id)
        self.photos = FileNamespace(root: photos, owner: id)
        self.models = FileNamespace(root: models, owner: id)
    }
    public func stateSnapshot() async throws -> StorageStateSnapshot {
        try Task.checkCancellation()
        return state.withLock {
            StorageStateSnapshot(
                path: "storage.files",
                runtime: [
                    "closed": .flag($0.closed), "files": .count($0.files.count),
                    "documents": .count($0.documents.count),
                ])
        }
    }
    public func start() throws {
        do {
            try access.check()
            try FileManager.default.createDirectory(at: settings.root, withIntermediateDirectories: true)
            var location = settings.root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try location.setResourceValues(values)
        } catch {
            failures.report("files", "start", error)
            throw error
        }
    }
    public func file(_ namespace: FileNamespace, protection: DocumentFileProtection = .afterFirstUnlock) throws
        -> DiskFileStore
    {
        do {
            guard namespace.owner == id else { throw StorageError.forbidden }
            return try state.withLock { state in
                guard !state.closed else { throw StorageError.closed }
                let key = namespace.root.standardizedFileURL.path
                if let existing = state.files[key] {
                    guard state.fileProtection[key] == protection else { throw FileStorageError.busy }
                    return existing
                }
                guard state.closers.count < 256 else { throw StorageError.capacityExceeded }
                let store = try DiskFileStore(root: namespace.root, protection: protection, access: access)
                state.files[key] = store
                state.fileProtection[key] = protection
                state.closers.append { await store.close() }
                return store
            }
        } catch {
            failures.report("files", "file", error)
            throw error
        }
    }
    public func document<Value: Codable & Sendable>(
        _ type: Value.Type, in namespace: FileNamespace, name: String, maximumBytes: Int = 65_536,
        protection: DocumentFileProtection = .whileUnlocked
    ) throws -> FileDocumentStore<Value> {
        do {
            guard namespace.owner == id else { throw StorageError.forbidden }
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
                throw FileStorageError.invalidPath
            }
            return try state.withLock { state in
                guard !state.closed else { throw StorageError.closed }
                let url = namespace.root.appendingPathComponent(name)
                let key = url.standardizedFileURL.path
                if let existing = state.documents[key] {
                    guard let configuration = state.documentConfiguration[key], configuration.0 == maximumBytes,
                        configuration.1 == protection
                    else { throw DocumentStorageError.invalidConfiguration }
                    guard let store = existing as? FileDocumentStore<Value> else { throw DocumentStorageError.conflict }
                    return store
                }
                guard state.closers.count < 256 else { throw StorageError.capacityExceeded }
                let store = try FileDocumentStore<Value>(
                    url: url, maximumBytes: maximumBytes, protection: protection, access: access)
                state.documents[key] = store
                state.documentConfiguration[key] = (maximumBytes, protection)
                state.closers.append { await store.close() }
                return store
            }
        } catch {
            failures.report("files", "document", error)
            throw error
        }
    }
    public func beginClosing() {
        state.withLock {
            $0.closed = true
            access.close()
        }
    }
    public func close() async {
        let task = state.withLock { state in
            if let shutdown = state.shutdown { return shutdown }
            state.closed = true
            access.close()
            let closers = state.closers
            state.closers.removeAll()
            state.files.removeAll()
            state.documents.removeAll()
            state.fileProtection.removeAll()
            state.documentConfiguration.removeAll()
            let task = Task { for close in closers { await close() } }
            state.shutdown = task
            return task
        }
        await task.value
    }
}
/// An opaque configured location, not an independent IoC scope.
public struct FileNamespace: Sendable {
    fileprivate let root: URL
    fileprivate let owner: UUID
}
