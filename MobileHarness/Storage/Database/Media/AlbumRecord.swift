import Foundation
import StorageCore
import StorageFiles

public struct MediaMetadata: Sendable, Equatable {
    public let mime: String
    public let width: Int
    public let height: Int
    public let capturedAt: Date?
    public let origin: String
    public init(mime: String, width: Int, height: Int, capturedAt: Date?, origin: String) {
        self.mime = mime
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
        self.origin = origin
    }
    public var fileExtension: String {
        switch mime {
        case "image/png": "png"
        case "image/heic": "heic"
        case "video/quicktime": "mov"
        default: "jpg"
        }
    }
    public func validate() throws {
        guard ["image/jpeg", "image/heic", "image/png", "video/quicktime"].contains(mime), width > 0, height > 0,
            width <= 100_000, height <= 100_000, Int64(width) * Int64(height) <= 100_000_000,
            ["camera", "import"].contains(origin)
        else { throw FileStorageError.invalidFile }
    }
}
public struct AlbumMediaRecord: Sendable, Equatable {
    public let id: String
    public let metadata: MediaMetadata
    public let addedAt: Date
    public let createdAt: Date
    public let bytes: Int
    public init(id: String, metadata: MediaMetadata, addedAt: Date, createdAt: Date, bytes: Int) {
        self.id = id
        self.metadata = metadata
        self.addedAt = addedAt
        self.createdAt = createdAt
        self.bytes = bytes
    }
    public var sortDate: Date { metadata.capturedAt ?? createdAt }
}
public struct AlbumCursor: Sendable, Equatable, Codable {
    public let date: Date
    public let id: String
    public init(date: Date, id: String) {
        self.date = date
        self.id = id
    }
}
public struct AlbumPage: Sendable {
    public let items: [AlbumMediaRecord]
    public let next: AlbumCursor?
    public init(items: [AlbumMediaRecord], next: AlbumCursor?) {
        self.items = items
        self.next = next
    }
}

public struct PhotoDeletionCleanupFailure: Error, Sendable {
    public let underlying: any Error
    public init(_ error: any Error) { underlying = error }
}
