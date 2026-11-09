import Actions
import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import PlatformKit
import StorageCache
import StorageCore
import Testing

@testable import Agents

@Test func photoFeedbackReceiptsDecodePreviewMappingAndKeepActualSaveSeparateFromIssues() throws {
    let id = UUID().uuidString
    let old = Data("{\"previewID\":\"\(id)\",\"state\":\"saved\",\"alreadySaved\":true}".utf8)
    let receipt = try JSONDecoder().decode(CameraPhotoCommandReceipt.self, from: old)
    #expect(receipt.previewID == id && receipt.alreadySaved && receipt.feedbackIssues == nil)
    let committed = CameraPhotoCommandReceipt(previewID: id, state: .saved, feedbackIssues: ["sound: failed"])
    #expect(
        try JSONDecoder().decode(CameraPhotoCommandReceipt.self, from: JSONEncoder().encode(committed)) == committed)
    #expect(committed.state == .saved)
}

@Test func shortCueWAVRetainsHeaderRateAndActualSignedSamples() throws {
    let data = try PCMClipEncoding.wav16(samples: [-1, 0, 1], sampleRate: 48000)
    #expect(data.count == 50)
    #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
    #expect(Array(data[24..<28]) == [0x80, 0xbb, 0, 0])
    #expect(Array(data[44..<50]) == [1, 0x80, 0, 0, 0xff, 0x7f])
}

@Test(arguments: [[Float](), [Float.nan], [Float.infinity], [1.01], Array(repeating: Float(0), count: 48001)])
func invalidShortCuePCMNeverProducesPlayableBytes(_ samples: [Float]) async {
    #expect(throws: PCMClipEncoding.Failure.self) { try PCMClipEncoding.wav16(samples: samples, sampleRate: 48000) }
}

@Test(arguments: [0, 7999, 192001, Int.max]) func invalidShortCueRateRejectsBeforeHeaderArithmetic(_ rate: Int) {
    #expect(throws: PCMClipEncoding.Failure.self) { try PCMClipEncoding.wav16(samples: [0], sampleRate: rate) }
}

private actor PreviewPersistenceProbe {
    var values: [Data] = []
    var fails = false
    func fail(_ value: Bool) { fails = value }
    func save(_ data: Data) throws -> String {
        if fails { throw CameraControlError.unavailable }
        values.append(data)
        return "media_\(values.count)"
    }
    var count: Int { values.count }
}

@Test @MainActor func reshootKeepsEarlierPhotoReadableUntilCameraSessionCloses() async throws {
    let root = CacheContainer()
    let store = CameraPreviewStore(
        cache: root.cameraImages, prepare: { .init(data: $0, width: 1, height: 1) },
        persist: { _ in throw CameraControlError.unavailable })
    try store.openSession()
    let first = try await store.reserve()
    try await store.publish(Data([1]), id: first, width: 1, height: 1)
    let replacement = try await store.reserve()
    try await store.publish(Data([2]), id: replacement, width: 1, height: 1)
    #expect(store.catalog.map(\.previewID) == [first, replacement])
    #expect(store.catalog.allSatisfy { $0.status == "pending" })
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [replacement])
    try await store.load(first, scope: "s")
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [replacement, first])
    #expect(try store.original(first) == Data([1]))
    await store.endSession()
    #expect(store.catalog.isEmpty && root.cameraImages.retainedBytes == 0)
    #expect(try store.snapshot(scope: "s").images.isEmpty)
    await #expect(throws: (any Error).self) { try await store.load(first, scope: "s") }
    try await store.close()
    await root.close()
}

@Test @MainActor func previewStateSurvivesTurnsAndSelectsOldImagesWithoutPersisting() async throws {
    let root = CacheContainer()
    let persistence = PreviewPersistenceProbe()
    let store = CameraPreviewStore(
        cache: root.cameraImages,
        prepare: { .init(data: $0, width: 1, height: 1) },
        persist: { data in try await persistence.save(data) })
    try store.openSession()
    let context = AgentStateContext()
    try context.registerMedia(
        "actions.camera.preview", read: { try await store.snapshot(scope: $0) }, reset: { await store.reset(scope: $0) }
    )
    try context.open(session: "s")
    await context.synchronize(session: "s", dialog: "dialog_1")
    let a = try await store.reserve()
    try await store.publish(Data([1, 2]), id: a, width: 10, height: 20)
    let b = try await store.reserve()
    try await store.publish(Data([3, 4]), id: b, width: 20, height: 10)
    #expect(await persistence.count == 0)
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [b])
    let beforeHistoryRead = try store.snapshot(scope: "s")
    #expect(try store.original(a) == Data([1, 2]))
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [b])
    #expect(try store.snapshot(scope: "s").revision == beforeHistoryRead.revision)
    try await store.load(a, scope: "s")
    for _ in 0..<3 {
        let snapshot = try await context.multimodalSnapshot(session: "s", names: ["actions.camera.preview"])
        #expect(snapshot.images.map(\.id) == [b, a])
        #expect(snapshot.images.map(\.data) == [Data([3, 4]), Data([1, 2])])
    }
    #expect(try await context.multimodalSnapshot(session: "s", names: []).images.isEmpty)
    #expect(try await context.multimodalSnapshot(session: "s", names: ["actions.camera.preview"]).images.count == 2)
    await context.synchronize(session: "s", dialog: "dialog_2")
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [b])
    try await store.load(a, scope: "s")
    await persistence.fail(true)
    await #expect(throws: CameraControlError.self) { try await store.save(a) }
    #expect(try store.snapshot(scope: "s").images.count == 2)
    await persistence.fail(false)
    let saved = try await store.save(a)
    #expect(saved.previewID == a && saved.mediaID == "media_1")
    #expect(try await store.save(a).alreadySaved)
    #expect(await persistence.count == 1)
    try await store.load(a, scope: "s")
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [b, a])
    try store.unload(a, scope: "s")
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [b])
    #expect(try store.original(b) == Data([3, 4]))
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [b])
    #expect(store.cache.entries.count == 2)
    try await store.load(b, scope: "s")
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [b])
    _ = try await store.save(b)
    #expect(store.catalog.allSatisfy { $0.status == "saved" })
    try await store.close()
    await root.close()
}

@Test func previewCacheCommitsFIFOOnlyAfterSuccessfulCapture() throws {
    let cache = PreviewImageCache(maximumCount: 2, maximumBytes: 16, maximumImageBytes: 4)
    try cache.open("session")
    for n in 1...2 {
        let id = try cache.reserve(id: "preview_\(n)")
        try cache.publish(Data(repeating: UInt8(n), count: 4), reservation: id)
    }
    #expect(throws: StorageError.duplicate) { try cache.reserve(id: "preview_1") }
    let failed = try cache.reserve(id: "preview_3")
    #expect(throws: StorageError.self) { try cache.publish(Data(repeating: 0, count: 5), reservation: failed) }
    cache.cancel(failed)
    #expect(cache.entries.map(\.id) == ["preview_1", "preview_2"])
    let next = try cache.reserve(id: "preview_4")
    #expect(try cache.publish(Data([4]), reservation: next) == "preview_1")
    #expect(cache.entries.map(\.id) == ["preview_2", "preview_4"])
    cache.endSession()
    #expect(cache.retainedBytes == 0)
    try cache.open("new-session")
    #expect(try cache.reserve(id: "preview_1") == "preview_1")
    cache.close()
    #expect(throws: StorageError.closed) { try cache.open("again") }
}

@Test @MainActor func previewSelectionBoundAndLatestReplacementAreExplicit() async throws {
    let root = CacheContainer()
    let store = CameraPreviewStore(
        cache: root.cameraImages,
        prepare: { .init(data: $0, width: 1, height: 1) },
        persist: { _ in "media_1" })
    try store.openSession()
    var ids: [String] = []
    for value in 1...6 {
        let id = try await store.reserve()
        try await store.publish(Data([UInt8(value)]), id: id, width: 1, height: 1)
        ids.append(id)
    }
    for id in ids.prefix(4) { try await store.load(id, scope: "s") }
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [ids[5], ids[0], ids[1], ids[2], ids[3]])
    let selected = Array(ids.prefix(5))
    try await store.load(selected, scope: "s")
    #expect(try store.snapshot(scope: "s").images.map(\.id) == selected)
    let state = AgentStateContext()
    try state.open(session: "s")
    try state.registerMedia("actions.camera.preview", read: { try await store.snapshot(scope: $0) }, reset: { _ in })
    #expect(
        try await state.multimodalSnapshot(session: "s", names: ["actions.camera.preview"]).images.map(\.id) == selected
    )
    await #expect(throws: CameraPreviewStore.SelectionError.self) { try await store.load(ids[5], scope: "s") }
    await #expect(throws: CameraControlError.photoUnavailable) {
        try await store.load([ids[5], "preview_99"], scope: "s")
    }
    #expect(try store.snapshot(scope: "s").images.map(\.id) == selected)
    try store.unload(ids[0], scope: "s")
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [ids[5], ids[1], ids[2], ids[3], ids[4]])
    try await store.load(selected, scope: "s")
    let new = try await store.reserve()
    try await store.publish(Data([7]), id: new, width: 1, height: 1)
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [new] + selected.dropFirst())
    try await store.close()
}

@Test func stateImageAuditPersistsActualSubmittedBytes() throws {
    let bytes = Data("actual-submitted-image-bytes".utf8)
    let image = try ChatImage(id: "temporary", data: bytes)
    let request = try ChatRequest(messages: [.init(role: .user, content: "current state", images: [image])])
    let audit = try AgentModelRequestRecording(request).snapshot().requestJSON
    #expect(audit.contains(bytes.base64EncodedString()))
    #expect(audit.contains("temporary") && audit.contains("data"))
    let retained = try AgentModelRequestRecording(request).snapshot().requestJSON
    #expect(retained.contains(bytes.base64EncodedString()))
}

private actor PreviewPreparationGate {
    var fail = true
    var held = false
    var waiter: CheckedContinuation<Void, Never>?
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    func prepare(_ data: Data) async throws -> CameraPreviewStore.PreparedImage {
        if fail { throw CameraControlError.unavailable }
        if held {
            await withCheckedContinuation {
                waiter = $0
                started.continuation.yield(())
            }
        }
        return .init(data: data, width: 1, height: 1)
    }
    func hold() {
        fail = false
        held = true
    }
    func release() {
        waiter?.resume()
        waiter = nil
        held = false
    }
}

@Test @MainActor func previewPreparationFailureRetainsOriginalAndResetFencesLateLoad() async throws {
    let root = CacheContainer()
    let gate = PreviewPreparationGate()
    let store = CameraPreviewStore(
        cache: root.cameraImages,
        prepare: { try await gate.prepare($0) }, persist: { _ in "media_1" })
    try store.openSession()
    let id = try await store.reserve()
    await #expect(throws: CameraControlError.self) { try await store.publish(Data([8]), id: id, width: 1, height: 1) }
    #expect(try store.original(id) == Data([8]))
    #expect(try store.snapshot(scope: "s").images.isEmpty)
    #expect(String(decoding: try store.snapshot(scope: "s").facts, as: UTF8.self).contains("analysisFailure"))
    await gate.hold()
    let pending = Task { try await store.load(id, scope: "s") }
    var started = await gate.started.stream.makeAsyncIterator()
    await started.next()
    store.reset(scope: "s")
    await gate.release()
    await #expect(throws: CameraControlError.self) { try await pending.value }
    #expect(try store.snapshot(scope: "s").images.isEmpty)
    try await store.load(id, scope: "s")
    #expect(try store.snapshot(scope: "s").images.map(\.id) == [id])
    try await store.close()
    await #expect(throws: CameraControlError.self) { try await store.load(id, scope: "s") }
}

@Test(arguments: ["preview_1", "preview_2", "preview_9223372036854775807"])
func livePreviewIDsUseCanonicalNumbers(_ value: String) {
    #expect(PreviewImageID(rawValue: value)?.rawValue == value)
}
@Test(arguments: [
    "preview_0", "preview_-1", "preview_01", "preview_+1", "preview_1 ", "preview_9223372036854775808",
    "preview_11111111-1111-4111-8111-111111111111",
])
func invalidAndLegacyPreviewIDsCannotBecomeLiveActions(_ value: String) {
    #expect(PreviewImageID(rawValue: value) == nil)
}
@Test @MainActor func previewSessionClosureJoinsLatePreparationAndFencesReusedIDs() async throws {
    let root = CacheContainer()
    let gate = PreviewPreparationGate()
    let store = CameraPreviewStore(
        cache: root.cameraImages, prepare: { try await gate.prepare($0) }, persist: { _ in "media_1" })
    try store.openSession()
    let oldScope = try #require(store.sessionID)
    let first = try await store.reserve()
    await #expect(throws: CameraControlError.self) {
        try await store.publish(Data([1]), id: first, width: 1, height: 1)
    }
    await gate.hold()
    let loading = Task { try await store.load(first, scope: "s") }
    var starts = await gate.started.stream.makeAsyncIterator()
    await starts.next()
    let closing = Task { await store.endSession() }
    await Task.yield()
    await gate.release()
    await #expect(throws: CameraControlError.self) { try await loading.value }
    await closing.value
    #expect(root.cameraImages.retainedBytes == 0)
    try store.openSession()
    #expect(store.sessionID != oldScope)
    #expect(try await store.reserve() == "preview_1")
    try await store.publish(Data([2]), id: "preview_1", width: 1, height: 1)
    #expect(throws: CameraControlError.self) { try store.validateSession(oldScope) }
    #expect(try store.original(first) == Data([2]))
    try await store.close()
}

@Test @MainActor func previewTwentyImageFIFOAndVisibilityPreserveDisposition() async throws {
    let root = CacheContainer()
    let store = CameraPreviewStore(
        cache: root.cameraImages, prepare: { .init(data: $0, width: 1, height: 1) }, persist: { _ in "media_1" })
    try store.openSession()
    let scope = try #require(store.sessionID)
    for n in 1...20 {
        let id = try await store.reserve()
        try await store.publish(Data([UInt8(n)]), id: id, width: 1, height: 1)
        if n == 1 { try await store.load(id, scope: "s") }
    }
    let next = try await store.reserve()
    #expect(store.catalog.count == 20)
    try await store.publish(Data([21]), id: next, width: 1, height: 1)
    #expect(store.catalog.first?.previewID == "preview_2" && store.catalog.last?.previewID == "preview_21")
    #expect(store.catalog.first?.status == "pending")
    #expect(try store.snapshot(scope: "s").images.map(\.id) == ["preview_21"])
    #expect(throws: (any Error).self) { try store.original("preview_1") }
    store.modelVisible = false
    #expect(try store.snapshot(scope: "s").images.isEmpty)
    #expect(store.catalog.count == 20 && store.sessionID == scope)
    store.modelVisible = true
    try await store.load("preview_2", scope: "s")
    let snapshot = try store.snapshot(scope: "s")
    #expect(snapshot.images.map(\.id) == ["preview_21", "preview_2"])
    #expect(snapshot.images.allSatisfy { $0.resourceScope == scope })
    #expect(!String(decoding: snapshot.facts, as: UTF8.self).contains(scope))
    await store.endSession()
    #expect(store.catalog.isEmpty && root.cameraImages.retainedBytes == 0)
    try store.openSession()
    #expect(try await store.reserve() == "preview_1")
    try await store.close()
}

@Test func privateImageScopeTravelsToExecutionAndAuditWithoutChangingModelIdentity() throws {
    let scope = UUID().uuidString
    let envelope = OutputEnvelope(
        source: .assistant, context: ProcessingContext(sessionID: "s", source: "user"),
        output: .control("fixture"), resourceBindings: ["actions.camera.preview": scope])
    #expect(envelope.executionContext.resourceBindings["actions.camera.preview"] == scope)
    let copy = envelope.bindingResources(["actions.camera.preview": "new"])
    #expect(copy.executionContext.resourceBindings["actions.camera.preview"] == "new")
    #expect(envelope.executionContext.resourceBindings["actions.camera.preview"] == scope)
    let request = try ChatRequest(messages: [
        .init(role: .user, content: "look", images: [try ChatImage(id: "preview_1", data: Data([1]))])
    ])
    let audit = try AgentModelRequestRecording(
        request
    ).snapshot().requestJSON
    #expect(!audit.contains(scope) && audit.contains("preview_1"))
    #expect(!String(decoding: try JSONEncoder().encode(request.messages), as: UTF8.self).contains(scope))
}

@Test @MainActor func closingCameraCancelsOwnedPreparationBeforeClearingSession() async throws {
    let root = CacheContainer()
    let started = AsyncStream<Void>.makeStream()
    let store = CameraPreviewStore(
        cache: root.cameraImages,
        prepare: { data in
            started.continuation.yield(())
            try await Task.sleep(for: .seconds(60))
            return .init(data: data, width: 1, height: 1)
        }, persist: { _ in "media_1" })
    try store.openSession()
    let id = try await store.reserve()
    let publishing = Task { try await store.publish(Data([1]), id: id, width: 1, height: 1) }
    var events = started.stream.makeAsyncIterator()
    await events.next()
    await store.endSession()
    await #expect(throws: CancellationError.self) { try await publishing.value }
    #expect(store.sessionID == nil && store.catalog.isEmpty && root.cameraImages.retainedBytes == 0)
    #expect(try store.snapshot(scope: "s").images.isEmpty)
    try store.openSession()
    #expect(try await store.reserve() == "preview_1")
    try await store.close()
}

private actor BatchPhotoAlbum {
    private var rejected = true
    private(set) var writes: [UInt8] = []

    func save(_ data: Data) throws -> String {
        let value = try #require(data.first)
        if value == 2, rejected { throw CameraControlError.unavailable }
        writes.append(value)
        return "media_\(value)"
    }

    func allowRemainingPhoto() { rejected = false }
}

@Test @MainActor func saveAllPhotosPreservesPartialSuccessAndOnlyRetriesPendingPhotos() async throws {
    let album = BatchPhotoAlbum()
    let root = CacheContainer()
    let store = CameraPreviewStore(
        cache: root.cameraImages, prepare: { .init(data: $0, width: 1, height: 1) },
        persist: { try await album.save($0) })
    try store.openSession()
    for n in 1...3 {
        let id = try await store.reserve()
        try await store.publish(Data([UInt8(n)]), id: id, width: 1, height: 1)
    }
    let first = try await store.saveAll()
    #expect(first.saved.map(\.mediaID) == ["media_1", "media_3"])
    #expect(first.failures.map(\.previewID) == ["preview_2"])
    #expect(store.catalog.map(\.status) == ["saved", "pending", "saved"])
    await album.allowRemainingPhoto()
    let second = try await store.saveAll()
    #expect(second.saved.map(\.previewID) == ["preview_2"] && second.failures.isEmpty)
    #expect(try await store.saveAll().saved.isEmpty)
    #expect(await album.writes == [1, 3, 2])
    await store.endSession()
    #expect(store.catalog.isEmpty && root.cameraImages.retainedBytes == 0)
    #expect(await album.writes == [1, 3, 2])
    try await store.close()
}
