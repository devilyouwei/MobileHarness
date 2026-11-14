import Foundation
import Synchronization
import Testing

@testable import UI

@MainActor private final class IslandSystemProbe: IslandSystemDriving {
    var onStatus: (@MainActor (UUID, IslandSystemStatus) -> Void)?
    var values: [IslandSystemSnapshot?] = []
    var result = IslandSystemStatus.active
    var failing = false
    var holdFirst = false
    var release: CheckedContinuation<Void, Never>?
    enum Failure: Error { case rejected }
    func apply(_ snapshot: IslandSystemSnapshot?) async throws -> IslandSystemStatus {
        values.append(snapshot)
        if holdFirst && values.count == 1 { await withCheckedContinuation { release = $0 } }
        if failing { throw Failure.rejected }
        return snapshot == nil ? .ended : result
    }
}
private func systemSnapshot(_ title: String) -> IslandSystemSnapshot {
    .init(
        generation: UUID(), activityID: UUID(), title: title, subtitle: "状态", primary: .symbol(name: "timer"),
        tone: "blue",
        updatedAt: Date())
}
@Test func islandContentDecodesOlderPayloadAndBoundsSystemWireData() throws {
    let older = IslandContent(title: "旧内容", primary: .symbol(name: "mic.fill"))
    let data = try JSONEncoder().encode(older)
    let decoded = try JSONDecoder().decode(IslandContent.self, from: data)
    #expect(decoded.liveActivity == nil)
    var optedIn = older
    optedIn.liveActivity = true
    #expect(try JSONDecoder().decode(IslandContent.self, from: JSONEncoder().encode(optedIn)).liveActivity == true)
    var snapshot = systemSnapshot("系统状态")
    #expect(try snapshot.validatedPayload().count < 3500)
    snapshot.title = String(repeating: "大", count: 1500)
    #expect(throws: IslandSystemSnapshot.IslandErrorPayload.self) { _ = try snapshot.validatedPayload() }
}
@Test func islandSystemSnapshotRejectsRetiredPersistedShape() throws {
    let value = systemSnapshot("旧版本活动")
    var object = try #require(try JSONSerialization.jsonObject(with: value.validatedPayload()) as? [String: Any])
    for key in [
        "paused", "attentionID", "primary", "secondary", "destination", "linkTitle", "detailPrimary", "detailTone",
        "hasStatus",
    ] {
        object.removeValue(forKey: key)
    }
    object["symbol"] = "timer"
    object["trailing"] = "recording"
    object["detailSymbol"] = "old-detail-icon"
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(IslandSystemSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

}
@Test @MainActor func islandSystemWriterCoalescesAndIgnoresLateNativeStatus() async throws {
    let driver = IslandSystemProbe()
    driver.holdFirst = true
    var statuses: [IslandSystemStatus] = []
    let presenter = IslandSystemPresentation(driver: driver) { status, _ in statuses.append(status) }
    let first = systemSnapshot("first")
    let middle = systemSnapshot("middle")
    let last = systemSnapshot("last")
    presenter.submit(first)
    let deadline = ContinuousClock.now + .seconds(3)
    while driver.release == nil && ContinuousClock.now < deadline { await Task.yield() }
    #expect(driver.release != nil)
    presenter.submit(middle)
    presenter.submit(last)
    driver.onStatus?(first.activityID, .dismissed)
    #expect(!statuses.contains(.dismissed))
    driver.release?.resume()
    driver.release = nil
    await presenter.flush()
    #expect(driver.values.compactMap { $0?.title } == ["first", "last"])
    #expect(statuses.last == .active)
    var unchanged = last
    unchanged.updatedAt = last.updatedAt.addingTimeInterval(1)
    presenter.submit(unchanged)
    await presenter.flush()
    #expect(driver.values.count == 2)
    driver.onStatus?(last.activityID, .dismissed)
    #expect(statuses.last == .dismissed)
    await presenter.stop()
    #expect(driver.values.last.flatMap { $0 } == nil && statuses.last == .ended)
    let count = driver.values.count
    presenter.submit(first)
    await presenter.flush()
    #expect(driver.values.count == count)
}
@Test @MainActor func islandSystemFailureAndPermissionDenialNeverBecomeSuccess() async {
    let driver = IslandSystemProbe()
    driver.failing = true
    var status = IslandSystemStatus.idle
    var issue: String?
    let presenter = IslandSystemPresentation(driver: driver) {
        status = $0
        issue = $1
    }
    presenter.submit(systemSnapshot("失败"))
    await presenter.flush()
    #expect(status == .failed && issue != nil)
    driver.failing = false
    driver.result = .disabled
    presenter.submit(systemSnapshot("权限关闭"))
    await presenter.flush()
    #expect(status == .disabled)
    driver.result = .active
    presenter.submit(systemSnapshot("恢复"))
    await presenter.flush()
    #expect(status == .active && issue == nil)
    await presenter.stop()
}
@Test @MainActor func islandSystemSelectionIncludesVoiceAndStopsWithRoot() async throws {
    let driver = IslandSystemProbe()
    let state = IslandState()
    state.installSystemDriver(driver)
    state.setAvailable(true)
    let task = UUID()
    try state.publish(
        id: task, owner: "task", revision: 1,
        content: .init(title: "任务", primary: .symbol(name: "timer"), priority: .normal, liveActivity: true),
        generation: state.generation, creating: true)
    try state.publish(
        id: UUID(), owner: "voice", revision: 1,
        content: .init(title: "说话", primary: .symbol(name: "speaker.wave.2"), priority: .high, secondary: .spectrum),
        generation: state.generation, creating: true)
    let deadline = ContinuousClock.now + .seconds(3)
    while state.systemStatus != .active && ContinuousClock.now < deadline { await Task.yield() }
    #expect(state.selected?.content.title == "说话")
    #expect(driver.values.last.flatMap { $0 }?.title == "说话")
    state.setAvailable(false)
    await state.stop()
    #expect(driver.values.last.flatMap { $0 } == nil && state.systemStatus == .ended)
}

@Test @MainActor func islandBackgroundSubmitsPausedSnapshotWithoutClaimingDeviceWork() async throws {
    let driver = IslandSystemProbe()
    let state = IslandState()
    state.installSystemDriver(driver)
    state.setAvailable(true)
    try state.publishSlot(
        owner: "task", content: .init(title: "任务", primary: .symbol(name: "scope"), startedAt: .now, expansionID: "one")
    )
    try await state.flushSystem(expectedGeneration: state.generation)
    state.setAvailable(false)
    let deadline = ContinuousClock.now + .seconds(3)
    while driver.values.last.flatMap({ $0 })?.paused != true && ContinuousClock.now < deadline { await Task.yield() }
    let paused = try #require(driver.values.last.flatMap { $0 })
    #expect(paused.paused && paused.startedAt == nil && paused.attentionID == nil)
    #expect(state.activities.isEmpty)
    await state.stop()
    #expect(driver.values.last.flatMap { $0 } == nil)
}

@Test @MainActor func islandBothSurfacesKeepGoalDetailWhileCameraTakesHeader() async throws {
    let driver = IslandSystemProbe()
    let state = IslandState()
    state.installSystemDriver(driver)
    state.setAvailable(true)
    try state.publishSlot(
        owner: "goal",
        content: .init(
            title: "目标", primary: .symbol(name: "scope"), priority: .normal,
            expansionID: "goal-one", detail: .init(text: "拍摄一张照片")))
    try state.publishSlot(
        owner: "camera", content: .init(title: "拍照中", primary: .symbol(name: "camera"), priority: .critical))
    try await state.flushSystem(expectedGeneration: state.generation)
    let snapshot = try #require(driver.values.last.flatMap { $0 })
    #expect(snapshot.primary == state.compact?.content.primary)
    #expect(snapshot.detailText == "拍摄一张照片" && state.detail?.text == snapshot.detailText)
    #expect(snapshot.detailPrimary == .symbol(name: "scope") && snapshot.hasStatus)
    #expect(snapshot.activityID == state.detailActivity?.id && snapshot.attentionID != nil)
    #expect(try JSONDecoder().decode(IslandSystemSnapshot.self, from: snapshot.validatedPayload()) == snapshot)
    let count = driver.values.count
    try state.spectrum(Array(repeating: 0.4, count: 32), active: true, generation: state.generation)
    #expect(driver.values.count == count)
    try state.publishSlot(owner: "goal", content: nil)
    try await state.flushSystem(expectedGeneration: state.generation)
    #expect(!state.expanded && driver.values.last.flatMap { $0 }?.detailText == nil)
    await state.stop()
}

@Test @MainActor func islandPauseKeepsGoalAndCameraSnapshot() async throws {
    let driver = IslandSystemProbe()
    let state = IslandState()
    state.installSystemDriver(driver)
    state.setAvailable(true)
    try state.publishSlot(
        owner: "goal",
        content: .init(
            title: "目标", primary: .symbol(name: "scope"), priority: .normal,
            expansionID: "goal-one", detail: .init(text: "拍摄一张照片")))
    try state.publishSlot(
        owner: "camera", content: .init(title: "拍照中", primary: .symbol(name: "camera"), priority: .critical))
    try await state.flushSystem(expectedGeneration: state.generation)
    state.setAvailable(false)
    let deadline = ContinuousClock.now + .seconds(3)
    while driver.values.last.flatMap({ $0 })?.paused != true && ContinuousClock.now < deadline { await Task.yield() }
    let paused = try #require(driver.values.last.flatMap { $0 })
    #expect(paused.paused && paused.detailText == "拍摄一张照片" && paused.primary == .symbol(name: "camera"))
    #expect(paused.attentionID == nil && !state.expanded)
    await state.stop()
}

@Test @MainActor func islandBackgroundKeepsLiveContentAndRestoresLocalPreference() async throws {
    let state = IslandState()
    let driver = IslandSystemProbe()
    state.installSystemDriver(driver)
    state.setAvailable(true)
    let generation = state.generation
    var content = IslandContent(title: "目标", primary: .symbol(name: "scope"), detail: .init(text: "继续对话"))
    let id = try #require(try state.publishSlot(owner: "task", content: content))
    try state.setExpanded(false)
    try await state.flushSystem(expectedGeneration: generation)
    state.setSceneActive(false)
    #expect(state.available && state.generation == generation)
    #expect(state.activities.count == 1 && !state.expanded)
    content.detail = .init(text: "后台已收到回复")
    content.secondary = .spectrum
    #expect(try state.publishSlot(owner: "task", content: content) == id)
    try await state.flushSystem(expectedGeneration: generation)
    let snapshot = try #require(driver.values.last ?? nil)
    #expect(snapshot.detailText == "后台已收到回复" && !snapshot.paused)
    #expect(snapshot.activityID == id && snapshot.generation == generation)
    #expect(state.localStatus == "detached")
    state.setSceneActive(true)
    #expect(state.activities.first?.content == content && !state.expanded)
    #expect(state.generation == generation)
    await state.stop()
    #expect(driver.values.last == .some(nil))
}

@Test @MainActor func islandSystemChannelsFilterEligibilityAndKeepDetailIdentityDuringStatusUpdates() async throws {
    let driver = IslandSystemProbe()
    let state = IslandState()
    state.installSystemDriver(driver)
    state.setAvailable(true)
    let goal = try #require(
        try state.publishSlot(
            owner: "goal",
            content: .init(
                title: "目标", primary: .symbol(name: "scope"), priority: .normal,
                expansionID: "one", detail: .init(text: "拍照"))))
    try await state.flushSystem(expectedGeneration: state.generation)
    let initial = try #require(driver.values.last.flatMap { $0 })
    #expect(!initial.hasStatus && initial.detailPrimary == .symbol(name: "scope"))
    try state.publishSlot(
        owner: "local",
        content: .init(
            title: "本地状态", primary: .symbol(name: "bell"), priority: .critical, liveActivity: false))
    for symbol in ["mic.fill", "speaker.wave.2.fill", "camera.fill", "sparkles"] {
        try state.publishSlot(
            owner: "status",
            content: .init(
                title: symbol, primary: .symbol(name: symbol), priority: .low, secondary: .loading))
        try await state.flushSystem(expectedGeneration: state.generation)
        let snapshot = try #require(driver.values.last.flatMap { $0 })
        #expect(snapshot.activityID == goal && snapshot.attentionID == initial.attentionID)
        #expect(snapshot.primary == .symbol(name: symbol) && snapshot.hasStatus)
        #expect(snapshot.detailPrimary == initial.detailPrimary && snapshot.detailText == "拍照")
        #expect(state.headerActivity?.content.title == "本地状态")
    }
    await state.stop()
}

@Test func islandExpiredSnapshotCannotKeepRecordingOrListeningIndicators() {
    var value = systemSnapshot("正在录音")
    value.primary = .symbol(name: "mic.fill", effect: .pulse)
    value.secondary = .elapsed(startedAt: Date())
    value.startedAt = Date()
    value.deadline = Date().addingTimeInterval(300)
    value.detailText = "拍摄照片"
    value.detailPrimary = .symbol(name: "scope")
    #expect(value.presentation(stale: false) == value)
    let stale = value.presentation(stale: true)
    #expect(stale.title == "Status expired" && stale.primary == .symbol(name: "pause.circle"))
    #expect(stale.secondary == nil && stale.startedAt == nil && stale.deadline == nil)
    #expect(!stale.hasStatus && stale.detailText != value.detailText && stale.detailPrimary == stale.primary)
    #expect(stale.endedAt == nil)  // Staleness is not proof that ActivityKit ended the activity.
    value.paused = true
    #expect(value.presentation(stale: false).title == "Updates paused")
    value.endedAt = Date()
    #expect(value.presentation(stale: false).title == "Activity ended")
    value.language = "zh-Hans"
    #expect(value.presentation(stale: false).title == "活动已结束")
}

@Test func islandTerminationCleanupFinishesBeforeReturningOrReportsTimeout() async {
    let completed = Mutex(false)
    #expect(IslandTerminationCleanup.perform { completed.withLock { $0 = true } })
    #expect(completed.withLock { $0 })
    let gate = AsyncStream<Void>.makeStream()
    #expect(
        !IslandTerminationCleanup.perform(timeout: 0.01) {
            for await _ in gate.stream {}
        })
    gate.continuation.finish()
}

@Test @MainActor func islandDriverInstallationReconcilesOrphansBeforeAnyBusinessPublication() async throws {
    let state = IslandState()
    let driver = IslandSystemProbe()
    state.setAvailable(true)
    state.installSystemDriver(driver)
    try await state.flushSystem(expectedGeneration: state.generation)
    #expect(driver.values.count == 1 && driver.values[0] == nil)
    try state.publishSlot(owner: "voice", content: .init(title: "聆听", primary: .symbol(name: "mic.fill")))
    try await state.flushSystem(expectedGeneration: state.generation)
    #expect(driver.values.count == 2 && driver.values[1]?.title == "聆听")
    await state.stop()
    #expect(driver.values.last.flatMap { $0 } == nil)
}
