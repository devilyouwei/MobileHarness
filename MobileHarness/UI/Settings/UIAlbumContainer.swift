import Foundation
import Observation

public struct AlbumPhoto: Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let date: Date
    public let mime: String
    public let width: Int
    public let height: Int
    public let bytes: Int
    public let origin: String
    public init(id: String, date: Date, mime: String, width: Int, height: Int, bytes: Int, origin: String) {
        self.id = id
        self.date = date
        self.mime = mime
        self.width = width
        self.height = height
        self.bytes = bytes
        self.origin = origin
    }
}
public struct AlbumPageToken: Sendable, Equatable {
    public let date: Date
    public let id: String
    public init(date: Date, id: String) {
        self.date = date
        self.id = id
    }
}
public struct AlbumImportSource: Sendable {
    public let load: @Sendable () async throws -> Data
    public init(load: @escaping @Sendable () async throws -> Data) { self.load = load }
}
public enum AlbumInput: Sendable {
    case page(AlbumPageToken?)
    case image(String, thumbnail: Bool)
    case importPhotos([AlbumImportSource])
    case export(String)
    case delete(String)
}
public enum AlbumReply: Sendable {
    case page([AlbumPhoto], AlbumPageToken?)
    case image(Data)
    case imported(Int, [String])
    case deleted(String, cleanupIssue: String?)
    case completed
}

@MainActor @Observable public final class UIAlbumContainer {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        return UIStateSnapshot(
            path: "ui.album",
            business: [
                "content": .text(contextSnapshot().content.rawValue),
                "operation": operation.map { .text($0.rawValue) } ?? .unknown,
                "loadedCount": .count(items.count), "hasMore": .flag(next != nil),
                "loading": .flag(loading), "busy": .flag(busy), "hasLoaded": .flag(hasLoaded),
            ])
    }

    public let requests = UIRequests<AlbumInput, AlbumReply>()
    public private(set) var items: [AlbumPhoto] = []
    public private(set) var next: AlbumPageToken?
    public private(set) var loading = false
    public private(set) var hasLoaded = false
    public private(set) var busy = false
    public private(set) var message: String?
    public private(set) var operation: PageOperation?
    private var loadFailed = false
    public struct ContextSnapshot: Encodable, Sendable, Equatable {
        public let content: PageContent
        public let loadedCount: Int
        public let hasMore: Bool
        public let operation: PageOperation?
        private enum CodingKeys: String, CodingKey { case content, loadedCount, hasMore, operation }
        public func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(content, forKey: .content)
            try fields.encode(loadedCount, forKey: .loadedCount)
            try fields.encode(hasMore, forKey: .hasMore)
            try fields.encode(operation, forKey: .operation)
        }
    }
    public func contextSnapshot() -> ContextSnapshot {
        ContextSnapshot(
            content: loading ? .loading : loadFailed ? .failed : !hasLoaded ? .idle : items.isEmpty ? .empty : .ready,
            loadedCount: items.count, hasMore: next != nil, operation: operation)
    }
    private var generation = UUID()
    @ObservationIgnored private var mutation: Task<Void, Never>?
    public init() {}
    public func loadMore(reset: Bool = false) async {
        guard !loading else { return }
        guard reset || !hasLoaded || next != nil else { return }
        loadFailed = false
        loading = true
        let ticket = generation
        defer { if ticket == generation { loading = false } }
        do {
            guard case .page(let values, let cursor) = try await requests.submit(.page(reset ? nil : next)) else {
                throw UIRequestError.stale
            }
            guard ticket == generation else { return }
            if reset { items = [] }
            let existing = Set(items.map(\.id))
            items += values.filter { !existing.contains($0.id) }
            next = cursor
            hasLoaded = true
        } catch is CancellationError {} catch {
            loadFailed = true
            message = error.localizedDescription
        }
    }
    public func image(_ id: String, thumbnail: Bool) async throws -> Data {
        guard case .image(let data) = try await requests.submit(.image(id, thumbnail: thumbnail)) else {
            throw UIRequestError.stale
        }
        return data
    }
    public func importPhotos(_ sources: [AlbumImportSource]) { mutate(.importPhotos(sources)) }
    public func export(_ id: String) { mutate(.export(id)) }
    public func delete(_ id: String) { mutate(.delete(id)) }
    public func clearMessage() { message = nil }
    private func mutate(_ value: AlbumInput) {
        guard mutation == nil else {
            message = "相册正在处理其他操作"
            return
        }
        switch value {
        case .importPhotos: operation = .importing
        case .export: operation = .exporting
        case .delete: operation = .deleting
        default: return
        }
        busy = true
        message = nil
        mutation = Task { [self] in
            defer {
                operation = nil
                busy = false
                mutation = nil
            }
            do {
                let reply = try await requests.submit(value)
                switch reply {
                case .imported(let count, let failures):
                    message =
                        "已导入 \(count) 张"
                        + (failures.isEmpty ? "" : "；失败 \(failures.count) 张：" + failures.joined(separator: "；"))
                case .deleted(let id, let cleanupIssue):
                    items.removeAll { $0.id == id }
                    message = cleanupIssue.map { "已从 App 相册删除，文件清理待重试：" + $0 } ?? "已从 App 相册删除"
                case .completed:
                    switch value {
                    case .export: message = "已保存到手机相册"
                    case .delete: message = "已从 App 相册删除"
                    default: break
                    }
                default: throw UIRequestError.stale
                }
            } catch is CancellationError { message = "操作已中断，请检查相册中的实际结果" } catch {
                message = error.localizedDescription
            }
            if case .export = value { return }
            // Retained root owns refresh, even if the page has disappeared.
            generation = UUID()
            loading = false
            await loadMore(reset: true)
        }
    }
    func stop() async {
        mutation?.cancel()
        await mutation?.value
        requests.stop()
        generation = UUID()
    }
}
