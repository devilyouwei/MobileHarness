import Foundation
import ImageIO
import Observation

public struct IslandActivity: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let owner: String
    public var revision: UInt64
    public var order: UInt64 = 0
    public var content: IslandContent
}
/// Root-owned bounded content shared by the local component and the system summary.
@Observable @MainActor public final class IslandState {
    public private(set) var activities: [IslandActivity] = []
    public private(set) var generation = UUID()
    public private(set) var available = false
    public private(set) var sceneActive = true
    public private(set) var localPresentationVisible = true
    public var expandedID: UUID? { detailActivity?.id }
    public var expanded: Bool {
        localPresentationVisible && (detailActivity.map { presentation[$0.id] ?? false } ?? false)
    }
    private var presentation: [UUID: Bool] = [:]
    private var retainedPresentation: [UUID: Bool]?
    private struct Thumbnail {
        let owner: String
        let data: Data
        var activityID: UUID?
    }
    private var thumbnails: [UUID: Thumbnail] = [:]
    @ObservationIgnored private var thumbnailWorker: Task<Data, any Error>?
    @ObservationIgnored private var thumbnailWorkerID: UUID?

    public private(set) var localRevision: UInt64 = 0
    public private(set) var localStatus = "detached"
    public private(set) var bands = [Float](repeating: 0, count: 32)
    public private(set) var spectrumActive = false
    public private(set) var message: String?
    public private(set) var systemStatus = IslandSystemStatus.unsupported
    public private(set) var systemError: String?
    @ObservationIgnored private var slots: [String: UUID] = [:]
    @ObservationIgnored private var publication: UInt64 = 0
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var ledger: [UUID: (owner: String, revision: UInt64)] = [:]
    @ObservationIgnored private var systemPresentation: IslandSystemPresentation?
    @ObservationIgnored private var attentionOverride: (id: UUID, token: String)?
    public private(set) var replacesSystemStatusBar = false
    /// Scene-window coordinates; layout reservation only, never a business control input.
    public private(set) var localFrame: CGRect?
    func reserveLocalFrame(_ frame: CGRect) {
        guard available, sceneActive, localPresentationVisible else { return }
        if localFrame != frame { localFrame = frame }
    }
    let statusBar: IslandStatusBarState
    public init(
        systemStatus: IslandDeviceStatusReading? = nil, onFailure: @escaping UIFailureReporting = { _, _, _ in }
    ) {
        statusBar = IslandStatusBarState(read: systemStatus, onFailure: onFailure)
    }
    func localMounted() {
        guard available, sceneActive, localPresentationVisible, compact != nil, !replacesSystemStatusBar else { return }
        replacesSystemStatusBar = true
        statusBar.start()
    }
    public var ranked: [IslandActivity] {
        activities.sorted {
            $0.content.rank == $1.content.rank ? $0.order > $1.order : $0.content.rank > $1.content.rank
        }
    }
    /// Detail and transient indicators have independent arbitration and lifetimes.
    public var selected: IslandActivity? {
        let eligible = ranked.filter { $0.content.liveActivity != false }
        return eligible.first { $0.content.detail != nil } ?? eligible.first
    }
    public var selectedID: UUID? { selected?.id }
    public var statusActivity: IslandActivity? { ranked.first { $0.content.detail == nil } }
    public var compact: IslandActivity? { statusActivity ?? detailActivity }
    public var headerActivity: IslandActivity? { expanded ? statusActivity : compact }
    public var detailActivity: IslandActivity? { ranked.first { $0.content.detail != nil } }
    public var detail: IslandDetail? { expanded ? detailActivity?.content.detail : nil }
    public func setExpanded(_ value: Bool, id: UUID? = nil) throws {
        guard available else { throw IslandError.unavailable }
        guard let target = id ?? detailActivity?.id ?? compact?.id,
            let item = activities.first(where: { $0.id == target })
        else { throw IslandError.missing }
        if value && item.content.detail?.normalized == nil { throw IslandError.invalid }
        presentation[target] = value && item.content.detail?.normalized != nil
        localChanged()
    }
    /// Bounded display-only image registration. No files, URLs, network or device access.
    public func registerThumbnail(_ data: Data, owner: String, generation: UUID) async throws -> IslandThumbnailID {
        guard available, generation == self.generation else { throw IslandError.stale }
        guard !owner.isEmpty, owner.utf8.count <= 256, !data.isEmpty, data.count <= 4 * 1024 * 1024 else {
            throw IslandError.invalid
        }
        guard thumbnailWorker == nil else { throw IslandError.busy }
        guard thumbnails.count < 8 else { throw IslandError.capacity }
        let id = UUID()
        let worker = Task.detached { try IslandThumbnailDecoder.decode(data) }
        thumbnailWorker = worker
        thumbnailWorkerID = id
        defer {
            if thumbnailWorkerID == id {
                thumbnailWorker = nil
                thumbnailWorkerID = nil
            }
        }
        let decoded = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard available, generation == self.generation else { throw IslandError.stale }
        thumbnails[id] = Thumbnail(owner: owner, data: decoded)
        return id
    }
    public func releaseThumbnail(_ id: IslandThumbnailID, owner: String, generation: UUID) throws {
        guard available, generation == self.generation else { throw IslandError.stale }
        guard let value = thumbnails[id] else { throw IslandError.missing }
        guard value.owner == owner else { throw IslandError.owner }
        guard value.activityID == nil else { throw IslandError.busy }
        thumbnails[id] = nil
    }
    func thumbnailData(_ id: IslandThumbnailID?) -> Data? { id.flatMap { thumbnails[$0]?.data } }
    private func validateThumbnail(_ id: IslandThumbnailID?, owner: String, activityID: UUID) throws {
        guard let id else { return }
        guard let value = thumbnails[id] else { throw IslandError.missing }
        guard value.owner == owner else { throw IslandError.owner }
        guard value.activityID == nil || value.activityID == activityID else { throw IslandError.busy }
    }
    public func spectrum(_ values: [Float], active: Bool, generation: UUID) throws {
        guard available, generation == self.generation else { throw IslandError.stale }
        guard values.count == 32, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw IslandError.invalid
        }
        spectrumActive = active
        bands = active ? values : [Float](repeating: 0, count: 32)
    }
    private func localChanged() {
        localRevision &+= 1
        localStatus = sceneActive && localPresentationVisible ? "pending" : "detached"
    }
    /// Navigation suspends only local presentation; activity and system lifetimes remain independent.
    func setLocalPresentationVisible(_ visible: Bool) {
        guard localPresentationVisible != visible else { return }
        if visible {
            for item in activities where item.content.detail != nil {
                if let expanded = retainedPresentation?[item.id] { presentation[item.id] = expanded }
            }
            retainedPresentation = nil
        } else {
            retainedPresentation = presentation
        }
        localPresentationVisible = visible
        if !visible { localDetached() }
        localChanged()
    }
    public func setSceneActive(_ active: Bool) {
        guard sceneActive != active else { return }
        sceneActive = active
        if !active { localDetached() }
        localChanged()
        synchronizeSystemPresentation()
    }
    func localDetached() {
        localStatus = "detached"
        replacesSystemStatusBar = false
        localFrame = nil
        statusBar.stop()
    }
    func localCompleted(generation: UUID, revision: UInt64) {
        guard available, sceneActive, localPresentationVisible,
            self.generation == generation, localRevision == revision
        else { return }
        localStatus = "settled"
    }
    public func setAvailable(_ value: Bool) {
        guard !stopped, available != value else { return }
        available = value
        #if os(iOS)
            if value && systemPresentation == nil { installSystemDriver(IslandLiveActivityDriver()) }
        #endif
        if !value {
            localDetached()
            if var paused = systemSnapshot() {
                paused.subtitle = "已暂停更新 · 返回 App 查看"
                paused.paused = true
                paused.startedAt = nil
                paused.deadline = nil
                paused.attentionID = nil
                systemPresentation?.submit(paused)
            } else {
                systemPresentation?.submit(nil)
            }
            generation = UUID()
            message = nil
            activities.removeAll()
            ledger.removeAll()
            slots.removeAll()
            attentionOverride = nil
            presentation.removeAll()
            retainedPresentation = nil
            thumbnails.removeAll()
            thumbnailWorker?.cancel()
            spectrumActive = false
            bands = [Float](repeating: 0, count: 32)
            localRevision &+= 1
            localStatus = "detached"
        }
    }
    public func stop() async {
        setAvailable(false)
        stopped = true
        _ = await thumbnailWorker?.result
        await systemPresentation?.stop()
    }
    /// Stable, bounded producer slots share the same activity ledger and admission rules.
    @discardableResult public func publishSlot(owner: String, content: IslandContent?) throws -> UUID? {
        guard available, !stopped else { throw IslandError.unavailable }
        guard !owner.isEmpty, owner.utf8.count <= 256 else { throw IslandError.invalid }
        let existingID = slots[owner]
        let existing = activities.first { $0.id == existingID }
        if existing?.content == content { return existingID }
        if content == nil && existing == nil { return existingID }
        guard existingID != nil || slots.count < 8 else { throw IslandError.capacity }
        let id = existingID ?? UUID()
        let lastRevision = ledger[id]?.revision ?? 0
        guard lastRevision < UInt64.max else { throw IslandError.capacity }
        let revision = lastRevision + 1
        if let content {
            try publish(
                id: id, owner: owner, revision: revision, content: content, generation: generation, creating: true)
            slots[owner] = id
        } else {
            try remove(id: id, owner: owner, revision: revision, generation: generation)
        }
        return id
    }
    public func end(id: UUID, owner: String, revision: UInt64) async throws {
        try Task.checkCancellation()
        let expected = generation
        try remove(id: id, owner: owner, revision: revision, generation: expected)
        try await flushSystem(expectedGeneration: expected)
    }
    public func requestAttention(id: UUID) async throws {
        try Task.checkCancellation()
        guard available else { throw IslandError.unavailable }
        guard let item = activities.first(where: { $0.id == id }) else { throw IslandError.missing }
        guard item.content.detail != nil else { throw IslandError.invalid }
        try setExpanded(true, id: id)
        if item.content.liveActivity == false { return }
        let expected = generation
        attentionOverride = (id, UUID().uuidString)
        synchronizeSystemPresentation()
        try await flushSystem(expectedGeneration: expected)
    }
    public func flushSystem(expectedGeneration: UUID) async throws {
        await systemPresentation?.flush()
        try Task.checkCancellation()
        guard available, generation == expectedGeneration else { throw IslandError.interrupted }
    }
    public func publish(
        id: UUID, owner: String, revision: UInt64, content: IslandContent,
        generation: UUID, creating: Bool
    ) throws {
        guard available, !stopped else { throw IslandError.unavailable }
        guard generation == self.generation, revision > 0 else { throw IslandError.stale }
        guard !owner.isEmpty, owner.utf8.count <= 256 else { throw IslandError.invalid }
        try content.validate()
        var content = content
        content.detail = content.detail?.normalized
        try validateThumbnail(content.detail?.thumbnail, owner: owner, activityID: id)
        if let known = ledger[id] {
            guard known.owner == owner else { throw IslandError.owner }
            guard
                revision > known.revision
                    || (revision == known.revision
                        && activities.contains(where: { $0.id == id && $0.content == content }))
            else { throw IslandError.stale }
        } else if ledger.count >= 256 {
            throw IslandError.capacity
        }
        let previousContent = activities.first { $0.id == id }?.content
        if let i = activities.firstIndex(where: { $0.id == id }) {
            guard activities[i].owner == owner else { throw IslandError.owner }
            guard revision > activities[i].revision else {
                if revision == activities[i].revision && content == activities[i].content { return }
                throw IslandError.stale
            }
            if attentionOverride?.id == id, activities[i].content.expansionID != content.expansionID {
                attentionOverride = nil
            }
            publication &+= 1
            activities[i].order = publication
            activities[i].revision = revision
            activities[i].content = content
        } else {
            guard creating else { throw IslandError.missing }
            guard activities.count < 8 else { throw IslandError.capacity }
            publication &+= 1
            activities.append(.init(id: id, owner: owner, revision: revision, order: publication, content: content))
        }
        ledger[id] = (owner, revision)
        if let old = previousContent?.detail?.thumbnail, old != content.detail?.thumbnail { thumbnails[old] = nil }
        if let image = content.detail?.thumbnail { thumbnails[image]?.activityID = id }
        if content.detail != nil {
            if previousContent?.detail == nil
                || (content.expansionID != nil && content.expansionID != previousContent?.expansionID)
            {
                presentation[id] = true
            }
        } else {
            presentation[id] = false
        }
        localChanged()
        synchronizeSystemPresentation()
    }
    public func remove(id: UUID, owner: String, revision: UInt64, generation: UUID) throws {
        guard available, self.generation == generation else { throw IslandError.unavailable }
        guard let i = activities.firstIndex(where: { $0.id == id }) else { throw IslandError.missing }
        guard activities[i].owner == owner else { throw IslandError.owner }
        guard revision > activities[i].revision else { throw IslandError.stale }
        ledger[id] = (owner, revision)
        if let image = activities[i].content.detail?.thumbnail { thumbnails[image] = nil }
        activities.remove(at: i)
        presentation[id] = nil
        retainedPresentation?[id] = nil
        if attentionOverride?.id == id { attentionOverride = nil }
        localChanged()
        synchronizeSystemPresentation()
    }
    public func report(_ error: any Error) { message = error.localizedDescription }
    func installSystemDriver(_ driver: any IslandSystemDriving) {
        guard systemPresentation == nil else { return }
        systemPresentation = IslandSystemPresentation(driver: driver) { [weak self] status, error in
            self?.systemStatus = status
            self?.systemError = error
        }
        systemStatus = .idle
        // Reconcile an earlier process even if this session never publishes a business activity.
        systemPresentation?.submit(nil, refresh: true)
    }
    private func synchronizeSystemPresentation() { systemPresentation?.submit(systemSnapshot()) }
    private func systemSnapshot() -> IslandSystemSnapshot? {
        let eligible = ranked.filter { $0.content.liveActivity != false }
        let status = eligible.first { $0.content.detail == nil }
        let detail = eligible.first { $0.content.detail != nil }
        var snapshot = (detail ?? status).map {
            IslandSystemSnapshot(activity: $0, status: status, generation: generation, now: Date())
        }
        if let override = attentionOverride, snapshot?.activityID == override.id {
            snapshot?.attentionID = override.token
        }
        return snapshot
    }
    public func stateSnapshot() async throws -> UIStateSnapshot {
        .init(
            path: "ui.island",
            business: [
                "activities": .array(
                    activities.map {
                        .object([
                            "id": .text($0.id.uuidString), "owner": .text($0.owner), "title": .text($0.content.title),
                            "canExpand": .flag($0.content.detail != nil),
                            "expanded": .flag(presentation[$0.id] ?? false),
                        ])
                    }),
                "selectedID": selectedID.map { .text($0.uuidString) } ?? .unknown,
                "presentation": .text("localAndSystem"), "expanded": .flag(expanded),
                "canExpand": .flag(detailActivity != nil),
                "statusID": statusActivity.map { .text($0.id.uuidString) } ?? .unknown,
                "detailID": expandedID.map { .text($0.uuidString) } ?? .unknown,
                "width": .unknown, "height": .unknown,
            ],
            runtime: [
                "available": .flag(available), "localStatus": .text(localStatus),
                "systemStatus": .text(systemStatus.rawValue),
                "systemError": systemError.map { .text($0) } ?? .unknown,
                "message": message.map { .text($0) } ?? .unknown,
            ])
    }
}

private enum IslandThumbnailDecoder {
    static func decode(_ data: Data) throws -> Data {
        try Task.checkCancellation()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 40_000_000,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { throw IslandError.invalid }
        try Task.checkCancellation()
        let result = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else {
            throw IslandError.invalid
        }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw IslandError.invalid }
        try Task.checkCancellation()
        return result as Data
    }
}
