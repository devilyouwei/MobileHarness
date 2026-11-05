import Foundation
import FunctionContracts
import PlatformKit
import StorageCore
import StorageMedia
import UI

public enum PhotoAlbumError: Error, Sendable, LocalizedError {
    case busy, unavailable, invalidRequest
    public var errorDescription: String? {
        switch self {
        case .busy: "相册正在处理其他操作，请稍后再试"
        case .unavailable: "媒体不可用"
        case .invalidRequest: "媒体格式不支持或超过大小限制"
        }
    }
}
public protocol PhotoAlbumCapability: Sendable {
    func perform(_ input: AlbumInput, owner: StorageOwner) async throws -> AlbumReply
}
public actor PhotoAlbumService: PhotoAlbumCapability {
    private let photos: MediaStore
    private let export: @Sendable (Data) async throws -> Void
    private let exportVideo: @Sendable (URL) async throws -> Void
    private var mutating = false
    private var originals = 0
    private var thumbnails = 0
    public init(
        photos: MediaStore, export: @escaping @Sendable (Data) async throws -> Void,
        exportVideo: @escaping @Sendable (URL) async throws -> Void = { _ in throw PhotoAlbumError.unavailable }
    ) {
        self.photos = photos
        self.export = export
        self.exportVideo = exportVideo
    }
    public func perform(_ input: AlbumInput, owner: StorageOwner) async throws -> AlbumReply {
        try Task.checkCancellation()
        switch input {
        case .page(let token):
            let page = try await photos.albumPage(before: token.map { AlbumCursor(date: $0.date, id: $0.id) })
            return .page(
                page.items.map { item in
                    AlbumPhoto(
                        id: item.id, date: item.sortDate, mime: item.metadata.mime, width: item.metadata.width,
                        height: item.metadata.height, bytes: item.bytes, origin: item.metadata.origin)
                }, page.next.map { AlbumPageToken(date: $0.date, id: $0.id) })
        case .video(let id):
            return .video(try await photos.videoURL(id))
        case .image(let id, let thumbnail):
            guard thumbnail ? thumbnails < 4 : originals < 2 else { throw PhotoAlbumError.busy }
            if thumbnail { thumbnails += 1 } else { originals += 1 }
            defer { if thumbnail { thumbnails -= 1 } else { originals -= 1 } }
            if try await photos.isAlbumVideo(id) {
                guard thumbnail else { throw PhotoAlbumError.invalidRequest }
                return .image(try await NativeAlbumMovie.thumbnail(photos.videoURL(id)))
            }
            let data = try await photos.readAlbum(id)
            #if canImport(ImageIO)
                return .image(thumbnail ? try await NativeAlbumImage.thumbnail(data) : data)
            #else
                throw PhotoAlbumError.unavailable
            #endif
        case .importPhotos(let sources):
            guard !mutating else { throw PhotoAlbumError.busy }
            guard !sources.isEmpty, sources.count <= 20 else { throw PhotoAlbumError.invalidRequest }
            mutating = true
            defer { mutating = false }
            var count = 0
            var failures: [String] = []
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                do {
                    let data = try await source.load()
                    #if canImport(ImageIO)
                        let info = try await NativeAlbumImage.inspect(data)
                        _ = try await photos.importPhoto(
                            data, owner: owner,
                            metadata: MediaMetadata(
                                mime: info.mime, width: info.width, height: info.height, capturedAt: info.capturedAt,
                                origin: "import"))
                        count += 1
                    #else
                        throw PhotoAlbumError.unavailable
                    #endif
                } catch is CancellationError { throw CancellationError() } catch {
                    failures.append("第\(index + 1)张：" + String(error.localizedDescription.prefix(160)))
                }
            }
            return .imported(count, failures)
        case .export(let id):
            guard !mutating else { throw PhotoAlbumError.busy }
            mutating = true
            defer { mutating = false }
            if try await photos.isAlbumVideo(id) {
                let file = try await photos.videoURL(id)
                try Task.checkCancellation()
                try await exportVideo(file)
            } else {
                let data = try await photos.readAlbum(id)
                try Task.checkCancellation()
                try await export(data)
            }
            return .completed
        case .delete(let id):
            guard !mutating else { throw PhotoAlbumError.busy }
            mutating = true
            defer { mutating = false }
            do {
                try await photos.deleteAlbum(id)
                return .deleted(id, cleanupIssue: nil)
            } catch let failure as PhotoDeletionCleanupFailure {
                return .deleted(id, cleanupIssue: String(failure.underlying.localizedDescription.prefix(256)))
            }
        }
    }
}

public typealias PhotoAlbumInvocation = ActionRequestSlot<AlbumInput, AlbumReply>

public enum PhotoAlbumActions {
    public static func function(using album: (any PhotoAlbumCapability)?) -> ActionFunction {
        ActionFunction(
            path: .init(domain: "Camera", module: "Album", function: "perform"), displayName: "管理 App 相册",
            kind: .finite, completion: "completed", timeout: .seconds(120),
            handler: { invocation in
                try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
                guard let request = invocation.attachment as? PhotoAlbumInvocation, let album else {
                    throw PhotoAlbumError.unavailable
                }
                try await request.accept(invocation)
                do {
                    let result = try await album.perform(
                        request.input,
                        owner: StorageOwner(
                            namespace: "photos", source: invocation.context.source,
                            session: invocation.context.sessionID, input: invocation.context.inputID))
                    try await request.complete(result)
                } catch {
                    await request.fail(error)
                    throw error
                }
            })
    }
}
