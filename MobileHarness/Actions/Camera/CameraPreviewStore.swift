import Foundation
import FunctionContracts
import StorageCache
import StorageCore

/// Camera owns session, selection and disposition policy; Storage owns ordered immutable images.
@MainActor public final class CameraPreviewStore {
    public enum SelectionError: Error, LocalizedError {
        case full([String])
        public var errorDescription: String? {
            switch self {
            case .full(let ids):
                "Preview selection is full; unload an explicit selection first. Loaded: " + ids.joined(separator: ", ")
            }
        }
    }
    public struct PreparedImage: Sendable {
        public let data: Data
        public let width: Int
        public let height: Int
        public init(data: Data, width: Int, height: Int) {
            self.data = data
            self.width = width
            self.height = height
        }
    }
    public struct Metadata: Codable, Sendable {
        public let previewID: String
        public let capturedAt: Date
        public let width: Int
        public let height: Int
        public let byteCount: Int
        public let status: String
        public let mediaID: String?
        public let analysisFailure: String?
    }
    private struct Facts: Encodable {
        let revision: UInt64
        let active: Bool
        let latestPreviewID: String?
        let loadedPreviewIDs: [String]
        let selectedPreviewIDs: [String]
        let previews: [Metadata]
    }
    public let cache: PreviewImageCache
    public var onChange: (@MainActor () -> Void)?
    public var modelVisible = true
    public var sessionID: String? { cache.scope }
    public var pendingCount: Int { cache.entries.filter { $0.disposition == .pending }.count }
    public var catalog: [Metadata] {
        cache.entries.map {
            .init(
                previewID: $0.id, capturedAt: $0.capturedAt, width: $0.width, height: $0.height,
                byteCount: $0.bytes, status: $0.disposition.rawValue, mediaID: $0.mediaID,
                analysisFailure: failures[$0.id])
        }
    }
    private let prepare: @Sendable (Data) async throws -> PreparedImage
    private let persist: @Sendable (Data) async throws -> String
    private var images: [String: ContextImage] = [:]
    private var failures: [String: String] = [:]
    private var selections: [String: [String]] = [:]
    private var latest: String?
    private var nextNumber: Int64 = 1
    private var revision: UInt64 = 0
    private var generation: UInt64 = 0
    private var busy = false
    private var preparation: Task<PreparedImage, Error>?
    private var closed = false
    private var ending: Task<Void, Never>?
    private var idle: CheckedContinuation<Void, Never>?
    public init(
        cache: PreviewImageCache, prepare: @escaping @Sendable (Data) async throws -> PreparedImage,
        persist: @escaping @Sendable (Data) async throws -> String
    ) {
        self.cache = cache
        self.prepare = prepare
        self.persist = persist
    }
    public func openSession() throws {
        guard !closed, ending == nil else { throw CameraControlError.unavailable }
        guard sessionID == nil else { return }
        try cache.open(UUID().uuidString)
        nextNumber = 1
        generation += 1
        changed()
    }
    public func validateSession(_ scope: String?) throws {
        guard !closed, ending == nil, let sessionID, scope == sessionID else {
            throw CameraControlError.photoUnavailable
        }
    }
    private func changed() {
        revision += 1
        onChange?()
    }
    private func finishBusy() {
        busy = false
        idle?.resume()
        idle = nil
    }
    public func endSession() async {
        if let ending {
            await ending.value
            return
        }
        generation += 1
        preparation?.cancel()
        let task = Task { @MainActor in
            if busy { await withCheckedContinuation { idle = $0 } }
            images.removeAll()
            failures.removeAll()
            selections.removeAll()
            latest = nil
            cache.endSession()
            changed()
        }
        ending = task
        await task.value
        ending = nil
    }
    public func close() async throws {
        closed = true
        await endSession()
    }
    public func reserve() async throws -> String {
        try Task.checkCancellation()
        try validateSession(sessionID)
        guard !busy else { throw CameraControlError.busy }
        guard nextNumber < Int64.max else { throw StorageError.capacityExceeded }
        let id = "preview_\(nextNumber)"
        _ = try cache.reserve(id: id)
        nextNumber += 1
        return id
    }
    public func cancelReservation(_ id: String) { cache.cancel(id) }
    public func publish(_ data: Data, id: String, width: Int, height: Int) async throws {
        try validateSession(sessionID)
        guard !busy else { throw CameraControlError.busy }
        if let removed = try cache.publish(data, reservation: id, width: width, height: height) {
            images[removed] = nil
            failures[removed] = nil
            for scope in selections.keys { selections[scope]?.removeAll { $0 == removed } }
        }
        latest = id
        releaseUnused()
        changed()
        do { try await load(id, scope: nil) } catch {
            if cache.entries.contains(where: { $0.id == id }) {
                failures[id] = String(String(describing: error).prefix(128))
                changed()
            }
            throw error
        }
    }
    public func original(_ id: String) throws -> Data { try cache.read(id) }
    public func load(_ id: String, scope: String?) async throws {
        try Task.checkCancellation()
        try validateSession(sessionID)
        guard cache.entries.contains(where: { $0.id == id }) else { throw CameraControlError.photoUnavailable }
        guard !busy else { throw CameraControlError.busy }
        if let scope {
            guard selections[scope] != nil || selections.count < 64 else { throw CameraControlError.busy }
            guard selections[scope, default: []].contains(id) || selections[scope, default: []].count < 3 else {
                throw SelectionError.full(loaded(scope))
            }
        }
        if images[id] != nil, scope.map({ selections[$0, default: []].contains(id) }) ?? true { return }
        busy = true
        let expected = generation
        defer {
            finishBusy()
            releaseUnused()
        }
        if images[id] == nil {
            let data = try cache.read(id)
            let task = Task { [prepare] in try await prepare(data) }
            preparation = task
            defer { preparation = nil }
            let prepared = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard !closed, ending == nil, expected == generation, let sessionID else {
                throw CameraControlError.photoUnavailable
            }
            guard !prepared.data.isEmpty, prepared.data.count <= 1024 * 1024, prepared.width > 0, prepared.height > 0,
                prepared.width <= 1568, prepared.height <= 1568, prepared.width * prepared.height <= 1_048_576
            else { throw CameraControlError.unavailable }
            try cache.storeAnalysis(prepared.data, id: id)
            images[id] = .init(
                id: id, width: prepared.width, height: prepared.height, data: prepared.data, resourceScope: sessionID)
        }
        if let scope, !selections[scope, default: []].contains(id) { selections[scope, default: []].append(id) }
        failures[id] = nil
        changed()
    }
    public func unload(_ id: String, scope: String) throws {
        try validateSession(sessionID)
        guard cache.entries.contains(where: { $0.id == id }) else { throw CameraControlError.photoUnavailable }
        generation += 1
        selections[scope]?.removeAll { $0 == id }
        releaseUnused()
        changed()
    }
    public func reset(scope: String) {
        generation += 1
        selections[scope] = nil
        releaseUnused()
        changed()
    }
    private func loaded(_ scope: String) -> [String] {
        var ids = latest.map { [$0] } ?? []
        for id in selections[scope, default: []] where !ids.contains(id) { ids.append(id) }
        return ids
    }
    public func snapshot(scope: String) throws -> MultimodalContextSnapshot {
        let active = !closed && ending == nil && sessionID != nil && modelVisible
        let ids = active ? loaded(scope) : []
        let facts = Facts(
            revision: revision, active: active, latestPreviewID: active ? latest : nil,
            loadedPreviewIDs: ids.filter { images[$0] != nil },
            selectedPreviewIDs: active ? selections[scope, default: []] : [],
            previews: active ? catalog : [])
        return .init(
            facts: try JSONEncoder().encode(facts), revision: revision, images: ids.compactMap { images[$0] },
            resourceScope: active ? sessionID : nil)
    }
    public func save(_ id: String) async throws -> CameraPhotoCommandReceipt {
        try validateSession(sessionID)
        guard let entry = cache.entries.first(where: { $0.id == id }) else { throw CameraControlError.photoUnavailable }
        guard !busy else { throw CameraControlError.busy }
        busy = true
        defer {
            finishBusy()
            releaseUnused()
        }
        try Task.checkCancellation()
        var mediaID = entry.mediaID
        if mediaID == nil { mediaID = try await persist(cache.read(id)) }
        try cache.mark(id, disposition: .saved, mediaID: mediaID)
        generation += 1
        for scope in selections.keys { selections[scope]?.removeAll { $0 == id } }
        if latest == id { latest = nil }
        images[id] = nil
        cache.removeAnalysis(id)
        changed()
        return .init(
            previewID: id, mediaID: mediaID, state: .saved, alreadySaved: entry.mediaID != nil
        )
    }
    private func releaseUnused() {
        let ids = Set(selections.values.flatMap { $0 }).union(latest.map { [$0] } ?? [])
        for id in Array(images.keys) where !ids.contains(id) {
            images[id] = nil
            cache.removeAnalysis(id)
        }
    }
}
