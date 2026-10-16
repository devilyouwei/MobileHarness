import Foundation
import StorageCore
import StorageFiles

/// Owned JPEG bytes with SQLite metadata. A public media ID is returned only after ready commits.
public actor CapturedPhotoStore {
    public enum OverflowPolicy: Sendable { case reject, evictOldest }
    public struct Limits: Sendable {
        public let maximumPhotos: Int
        public let maximumBytes: Int
        public let overflowPolicy: OverflowPolicy
        public init(
            maximumPhotos: Int = 32, maximumBytes: Int = 128 * 1024 * 1024,
            overflowPolicy: OverflowPolicy = .reject
        ) {
            self.maximumPhotos = maximumPhotos
            self.maximumBytes = maximumBytes
            self.overflowPolicy = overflowPolicy
        }
    }
    private let makeRepository: @Sendable () throws -> any MediaRepository
    private let makeFiles: @Sendable () throws -> any FileStore
    private let limits: Limits
    private var prepared = false
    private var cleanupCursor: String?
    private var cleanupFinished = false
    private let operationGate = StorageOperationGate()
    internal var waitingOperationCount: Int { get async { await operationGate.waitingCount } }
    public init(repository: any MediaRepository, files: any FileStore, limits: Limits = Limits()) {
        makeRepository = { repository }
        makeFiles = { files }
        self.limits = limits
    }
    public init(
        repository: Result<any MediaRepository, any Error>, files: Result<any FileStore, any Error>,
        limits: Limits = Limits()
    ) {
        makeRepository = { try repository.get() }
        makeFiles = { try files.get() }
        self.limits = limits
    }
    public init(
        repository: @escaping @Sendable () throws -> any MediaRepository,
        files: Result<any FileStore, any Error>, limits: Limits = Limits()
    ) {
        makeRepository = repository
        makeFiles = { try files.get() }
        self.limits = limits
    }
    public init(
        repository: @escaping @Sendable () throws -> any MediaRepository,
        files: @escaping @Sendable () throws -> any FileStore, limits: Limits = Limits()
    ) {
        makeRepository = repository
        makeFiles = files
        self.limits = limits
    }
    private func resetCleanup() async {
        if let cleanupCursor, let files = try? makeFiles() { await files.closeListing(cleanupCursor) }
        cleanupCursor = nil
        cleanupFinished = false
        prepared = false
    }
    private func prepare() async throws {
        let repository = try makeRepository()
        let files = try makeFiles()
        guard (1...8192).contains(limits.maximumPhotos), limits.maximumBytes > 0,
            limits.maximumBytes <= 32 * 1024 * 1024 * 1024
        else { throw FileStorageError.invalidFile }
        do {
            if !prepared {
                for item in try await repository.retainedMedia() where item.state == "pending" {
                    let info = try await files.info(item.path)
                    let complete = info?.bytes == item.bytes
                    try await repository.setMedia(
                        item.id, state: complete ? "ready" : "failed",
                        failure: complete ? nil : "Interrupted file publication")
                }
                prepared = true
            }
            try await cleanupStep(repository, files: files)
        } catch {
            await resetCleanup()
            throw error
        }
    }
    private func cleanupStep(_ repository: any MediaRepository, files: any FileStore) async throws {
        guard !cleanupFinished else { return }
        let retained = Set(try await repository.retainedMedia().map(\.path))
        let page = try await files.listObjects(cursor: cleanupCursor, limit: 128)
        cleanupCursor = page.next
        for name in page.keys {
            guard
                name.range(of: "^[0-9]{8}_[0-9]{6}_[0-9]+\\.jpg$", options: .regularExpression) != nil
                    || name.hasPrefix(".media-") || name.hasPrefix(".store-")
            else { continue }
            if !retained.contains(name) { try await files.remove(name) }
        }
        cleanupFinished = page.next == nil
    }
    public func save(_ data: Data, owner: StorageOwner, capturedAt: Date = Date()) async throws -> String {
        try await operationGate.withAccess { [self] in try await saveLocked(data, owner: owner, capturedAt: capturedAt)
        }
    }
    private func saveLocked(_ data: Data, owner: StorageOwner, capturedAt: Date = Date()) async throws -> String {
        try Task.checkCancellation()
        let repository = try makeRepository()
        let files = try makeFiles()
        guard owner.namespace == "photos", !owner.source.isEmpty, owner.source.utf8.count <= 64 else {
            throw FileStorageError.invalidFile
        }
        try await prepare()
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024, data.count <= limits.maximumBytes else {
            throw FileStorageError.capacityExceeded
        }
        let old = try await repository.retainedMedia()
        if limits.overflowPolicy == .reject,
            old.count >= limits.maximumPhotos || old.reduce(0, { $0 + $1.bytes }) + data.count > limits.maximumBytes
        {
            throw FileStorageError.capacityExceeded
        }
        let item = try await repository.reserveMedia(
            bytes: data.count, source: owner.source, session: owner.session, input: owner.input, date: capturedAt)
        var published = false
        do {
            try await files.putIfAbsent(data, key: item.path)
            published = true
            try await repository.setMedia(item.id, state: "ready")
        } catch {
            let original = error
            do {
                try await repository.setMedia(item.id, state: "failed", failure: String(describing: original))
                if published { try await files.remove(item.path) }
            } catch {
                await resetCleanup()
                throw BinaryPublicationError(publication: original, cleanup: error)
            }
            throw original
        }
        if limits.overflowPolicy == .evictOldest {
            var count = old.count + 1
            var bytes = old.reduce(data.count) { $0 + $1.bytes }
            for retired in old where count > limits.maximumPhotos || bytes > limits.maximumBytes {
                try await repository.setMedia(retired.id, state: "unavailable")
                do { try await files.remove(retired.path) } catch {
                    await resetCleanup()
                    throw error
                }
                count -= 1
                bytes -= retired.bytes
            }
        }
        return item.id
    }
    public func read(_ id: String, owner: StorageOwner) async throws -> Data {
        try await operationGate.withAccess { [self] in try await readLocked(id, owner: owner) }
    }
    private func readLocked(_ id: String, owner: StorageOwner) async throws -> Data {
        try await prepare()
        let repository = try makeRepository()
        guard owner.namespace == "photos", let item = try await repository.media(id), item.state == "ready",
            item.source == owner.source, item.session == owner.session, item.input == owner.input
        else { throw FileStorageError.invalidFile }
        return try await bytes(item)
    }
    public func readForInput(_ id: String, source: String, input: String) async throws -> Data? {
        try await operationGate.withAccess { [self] in try await readForInputLocked(id, source: source, input: input) }
    }
    private func readForInputLocked(_ id: String, source: String, input: String) async throws -> Data? {
        try await prepare()
        let repository = try makeRepository()
        let files = try makeFiles()
        guard let item = try await repository.media(id), item.state == "ready" else { return nil }
        guard item.source == source, item.input == input else { throw FileStorageError.invalidFile }
        guard try await files.info(item.path) != nil else { return nil }
        return try await bytes(item)
    }
    private func bytes(_ item: MediaFileRecord) async throws -> Data {
        guard let result = try await makeFiles().read(item.path, maximumBytes: 4 * 1024 * 1024),
            result.count == item.bytes
        else { throw FileStorageError.invalidFile }
        return result
    }
}
