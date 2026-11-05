import Foundation
import StorageCore
import StorageFiles

/// Owned JPEG bytes with SQLite metadata. A public media ID is returned only after ready commits.
public actor MediaStore {
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
            for item in try await repository.pendingMediaDeletions() {
                try await files.remove(item.path)
                try await repository.setMedia(item.id, state: "deleted")
            }
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
                    || name.range(of: "^[0-9A-Fa-f-]{36}\\.(jpg|png|heic|mov)$", options: .regularExpression) != nil
                    || name.hasPrefix(".media-") || name.hasPrefix(".store-")
            else { continue }
            if !retained.contains(name) { try await files.remove(name) }
        }
        cleanupFinished = page.next == nil
    }
    public func saveVideo(_ file: URL, owner: StorageOwner, metadata: MediaMetadata) async throws -> String {
        try await operationGate.withAccess { [self] in
            try Task.checkCancellation()
            guard owner.namespace == "photos", !owner.source.isEmpty, owner.source.utf8.count <= 64,
                metadata.mime == "video/quicktime"
            else { throw FileStorageError.invalidFile }
            try metadata.validate()
            try await prepare()
            let repository = try makeRepository()
            let files = try makeFiles()
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let count = values.fileSize, count > 0, count <= 512 * 1024 * 1024
            else { throw FileStorageError.capacityExceeded }
            let old = try await repository.retainedMedia()
            var retainedCount = old.count + 1
            var bytes = old.reduce(count) { $0 + $1.bytes }
            let protected = old.filter { $0.albumAddedAt != nil }
            guard protected.count + 1 <= limits.maximumPhotos,
                protected.reduce(count, { $0 + $1.bytes }) <= limits.maximumBytes
            else { throw FileStorageError.capacityExceeded }
            if retainedCount > limits.maximumPhotos || bytes > limits.maximumBytes {
                guard limits.overflowPolicy == .evictOldest else { throw FileStorageError.capacityExceeded }
                for retired in old
                where retired.albumAddedAt == nil
                    && (retainedCount > limits.maximumPhotos || bytes > limits.maximumBytes)
                {
                    try await repository.setMedia(retired.id, state: "unavailable")
                    try await files.remove(retired.path)
                    retainedCount -= 1
                    bytes -= retired.bytes
                }
            }
            let item = try await repository.reserveVideo(
                bytes: count, owner: owner, metadata: metadata, createdAt: Date())
            var published = false
            do {
                try await files.importFile(file, key: item.path, maximumBytes: 512 * 1024 * 1024)
                published = true
                try await repository.setMedia(item.id, state: "ready")
            } catch {
                let primary = error
                do {
                    try await repository.setMedia(item.id, state: "failed", failure: String(describing: primary))
                    if published { try await files.remove(item.path) }
                } catch { throw BinaryPublicationError(publication: primary, cleanup: error) }
                throw primary
            }
            return item.id
        }
    }
    public func isAlbumVideo(_ id: String) async throws -> Bool {
        try await operationGate.withAccess { [self] in
            try await prepare()
            guard let item = try await makeRepository().albumMedia(id) else { throw FileStorageError.invalidFile }
            return item.metadata.mime == "video/quicktime"
        }
    }
    public func videoURL(_ id: String, owner: StorageOwner? = nil) async throws -> URL {
        try await operationGate.withAccess { [self] in
            try await prepare()
            let repository = try makeRepository()
            guard let item = try await repository.media(id), item.state == "ready", item.path.hasSuffix(".mov") else {
                throw FileStorageError.invalidFile
            }
            if let owner {
                guard owner.namespace == "photos", item.source == owner.source, item.session == owner.session,
                    item.input == owner.input
                else { throw FileStorageError.invalidFile }
            } else {
                guard try await repository.albumMedia(id) != nil else { throw FileStorageError.invalidFile }
            }
            let files = try makeFiles()
            guard try await files.info(item.path)?.bytes == item.bytes else { throw FileStorageError.invalidFile }
            return try await files.fileURL(item.path, maximumBytes: 512 * 1024 * 1024)
        }
    }
    public func collectVideo(_ id: String, owner: StorageOwner) async throws {
        try await operationGate.withAccess { [self] in
            try await prepare()
            let repository = try makeRepository()
            guard let item = try await repository.media(id), item.state == "ready", item.path.hasSuffix(".mov"),
                owner.namespace == "photos", item.source == owner.source, item.session == owner.session,
                item.input == owner.input,
                try await makeFiles().info(item.path)?.bytes == item.bytes
            else { throw FileStorageError.invalidFile }
            try await repository.collectPhoto(id, metadata: nil, at: Date())
        }
    }
    public func discardVideo(_ id: String, owner: StorageOwner) async throws {
        try await operationGate.withAccess { [self] in
            try Task.checkCancellation()
            try await prepare()
            let repository = try makeRepository()
            guard let item = try await repository.media(id), item.albumAddedAt == nil, item.path.hasSuffix(".mov"),
                owner.namespace == "photos", item.source == owner.source, item.session == owner.session,
                item.input == owner.input
            else { throw FileStorageError.invalidFile }
            if item.state == "deleted" { return }
            try await repository.setMedia(id, state: "deleting")
            try await makeFiles().remove(item.path)
            try await repository.setMedia(id, state: "deleted")
        }
    }

    public func save(_ data: Data, owner: StorageOwner, capturedAt: Date = Date()) async throws -> String {
        try await operationGate.withAccess { [self] in try await saveLocked(data, owner: owner, capturedAt: capturedAt)
        }
    }
    private func saveLocked(
        _ data: Data, owner: StorageOwner, capturedAt: Date = Date(), metadata: MediaMetadata? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        let repository = try makeRepository()
        let files = try makeFiles()
        guard owner.namespace == "photos", !owner.source.isEmpty, owner.source.utf8.count <= 64 else {
            throw FileStorageError.invalidFile
        }
        try await prepare()
        guard !data.isEmpty, data.count <= (metadata == nil ? 4 : 32) * 1024 * 1024, data.count <= limits.maximumBytes
        else {
            throw FileStorageError.capacityExceeded
        }
        if let metadata {
            try metadata.validate()
            guard metadata.mime != "video/quicktime" else { throw FileStorageError.invalidFile }
        }
        let old = try await repository.retainedMedia()
        var count = old.count + 1
        var totalBytes = old.reduce(data.count) { $0 + $1.bytes }
        let reclaimable = old.filter { $0.albumAddedAt == nil }
        guard old.filter({ $0.albumAddedAt != nil }).count + 1 <= limits.maximumPhotos,
            old.filter({ $0.albumAddedAt != nil }).reduce(data.count, { $0 + $1.bytes }) <= limits.maximumBytes
        else { throw FileStorageError.capacityExceeded }
        if count > limits.maximumPhotos || totalBytes > limits.maximumBytes {
            guard limits.overflowPolicy == .evictOldest else { throw FileStorageError.capacityExceeded }
            for retired in reclaimable where count > limits.maximumPhotos || totalBytes > limits.maximumBytes {
                try await repository.setMedia(retired.id, state: "unavailable")
                try await files.remove(retired.path)
                count -= 1
                totalBytes -= retired.bytes
            }
        }
        let item: MediaFileRecord
        if let metadata {
            item = try await repository.reservePhoto(
                bytes: data.count, owner: owner, metadata: metadata, createdAt: capturedAt)
        } else {
            item = try await repository.reserveMedia(
                bytes: data.count, source: owner.source, session: owner.session, input: owner.input, date: capturedAt)
        }
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
        return item.id
    }
    public func collect(_ id: String, owner: StorageOwner, metadata: MediaMetadata) async throws {
        guard metadata.mime != "video/quicktime" else { throw FileStorageError.invalidFile }
        try await operationGate.withAccess { [self] in
            try await prepare()
            let repository = try makeRepository()
            guard let item = try await repository.media(id), item.state == "ready", item.source == owner.source,
                item.session == owner.session, item.input == owner.input
            else { throw FileStorageError.invalidFile }
            _ = try await bytes(item)
            try Task.checkCancellation()
            try await repository.collectPhoto(id, metadata: metadata, at: Date())
        }
    }
    public func importPhoto(_ data: Data, owner: StorageOwner, metadata: MediaMetadata) async throws -> String {
        try await operationGate.withAccess { [self] in
            let id = try await saveLocked(data, owner: owner, metadata: metadata)
            // Once bytes commit, finish the matching collection transaction before returning.
            try await makeRepository().collectPhoto(id, metadata: nil, at: Date())
            return id
        }
    }
    public func albumPage(before: AlbumCursor? = nil) async throws -> AlbumPage {
        try await operationGate.withAccess { [self] in
            try await prepare()
            return try await makeRepository().albumPage(before: before, limit: 40)
        }
    }
    public func readAlbum(_ id: String) async throws -> Data {
        try await operationGate.withAccess { [self] in
            try await prepare()
            let repository = try makeRepository()
            guard try await repository.albumMedia(id) != nil, let item = try await repository.media(id) else {
                throw FileStorageError.invalidFile
            }
            return try await bytes(item, maximumBytes: 32 * 1024 * 1024)
        }
    }
    public func deleteAlbum(_ id: String) async throws {
        try await operationGate.withAccess { [self] in
            try await prepare()
            let repository = try makeRepository()
            let files = try makeFiles()
            guard let item = try await repository.media(id) else { throw FileStorageError.invalidFile }
            try Task.checkCancellation()
            try await repository.deleteAlbumMedia(id)
            // Logical deletion is committed even if physical cleanup fails.
            do {
                try await files.remove(item.path)
                try await repository.setMedia(id, state: "deleted")
            } catch { throw PhotoDeletionCleanupFailure(error) }
        }
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
    private func bytes(_ item: MediaFileRecord, maximumBytes: Int = 4 * 1024 * 1024) async throws -> Data {
        guard !item.path.hasSuffix(".mov") else { throw FileStorageError.invalidFile }
        guard let result = try await makeFiles().read(item.path, maximumBytes: maximumBytes),
            result.count == item.bytes
        else { throw FileStorageError.invalidFile }
        return result
    }
}
