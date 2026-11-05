import Foundation
import StorageCore
import StorageFiles

public struct MediaFileRecord: Sendable {
    public let id: String
    public let path: String
    public let bytes: Int
    public let source: String
    public let session: String
    public let input: String
    public let albumAddedAt: Date?
    public let state: String
    public init(
        id: String, path: String, bytes: Int, source: String, session: String, input: String, state: String,
        albumAddedAt: Date? = nil
    ) {
        self.albumAddedAt = albumAddedAt
        self.id = id
        self.path = path
        self.bytes = bytes
        self.source = source
        self.session = session
        self.input = input
        self.state = state
    }
}

public protocol MediaRepository: Sendable {
    func reserveVideo(bytes: Int, owner: StorageOwner, metadata: MediaMetadata, createdAt: Date) async throws
        -> MediaFileRecord
    func reserveMedia(bytes: Int, source: String, session: String, input: String, date: Date) async throws
        -> MediaFileRecord
    func reservePhoto(bytes: Int, owner: StorageOwner, metadata: MediaMetadata, createdAt: Date) async throws
        -> MediaFileRecord
    func collectPhoto(_ id: String, metadata: MediaMetadata?, at: Date) async throws
    func albumPage(before: AlbumCursor?, limit: Int) async throws -> AlbumPage
    func albumMedia(_ id: String) async throws -> AlbumMediaRecord?
    func deleteAlbumMedia(_ id: String) async throws
    func pendingMediaDeletions() async throws -> [MediaFileRecord]
    func media(_ id: String) async throws -> MediaFileRecord?
    func retainedMedia() async throws -> [MediaFileRecord]
    func setMedia(_ id: String, state: String, failure: String?) async throws
}

extension MediaRepository {
    public func reserveVideo(bytes: Int, owner: StorageOwner, metadata: MediaMetadata, createdAt: Date) async throws
        -> MediaFileRecord
    { throw FileStorageError.invalidFile }

    public func setMedia(_ id: String, state: String) async throws {
        try await setMedia(id, state: state, failure: nil)
    }
}
