import Foundation
import ImageIO
import Synchronization
import Testing

@testable import UI

@MainActor private func islandItem(_ state: IslandState, owner: String, rank: Int) throws -> UUID {
    let id = UUID()
    try state.publish(
        id: id, owner: owner, revision: 1, content: .init(title: owner, primary: .symbol(name: "circle"), rank: rank),
        generation: state.generation, creating: true)
    return id
}
@Test @MainActor func islandEqualRankUsesLatestAndBackgroundInvalidatesOwners() throws {
    let state = IslandState()
    state.setAvailable(true)
    let first = try islandItem(state, owner: "first", rank: 50)
    let second = try islandItem(state, owner: "second", rank: 50)
    try state.publish(
        id: second, owner: "second", revision: 2,
        content: .init(title: "更新", primary: .symbol(name: "circle"), rank: 50), generation: state.generation,
        creating: false)
    #expect(state.selectedID == second)
    let old = state.generation
    state.setAvailable(false)
    state.setAvailable(true)
    #expect(state.activities.isEmpty && state.generation != old)
    #expect(throws: IslandError.stale) {
        try state.publish(
            id: first, owner: "first", revision: 3, content: .init(title: "迟到", primary: .symbol(name: "circle")),
            generation: old,
            creating: true)
    }
}
@Test @MainActor func islandCapacityOwnerAndRevisionRejectionsDoNotRemoveOtherActivities() throws {
    let state = IslandState()
    state.setAvailable(true)
    let id = try islandItem(state, owner: "first", rank: 50)
    for index in 1..<8 { _ = try islandItem(state, owner: "item\(index)", rank: 0) }
    #expect(throws: IslandError.capacity) { _ = try islandItem(state, owner: "overflow", rank: 100) }
    #expect(throws: IslandError.owner) {
        try state.remove(id: id, owner: "wrong", revision: 2, generation: state.generation)
    }
    #expect(throws: IslandError.stale) {
        try state.remove(id: id, owner: "first", revision: 1, generation: state.generation)
    }
    #expect(state.activities.count == 8 && state.selectedID == id)
}
@Test @MainActor func islandEndedActivityRejectsLateCreationAndCanResumeOnlyAtANewerRevision() throws {
    let state = IslandState()
    state.setAvailable(true)
    let id = try islandItem(state, owner: "task", rank: 50)
    try state.remove(id: id, owner: "task", revision: 2, generation: state.generation)
    #expect(throws: IslandError.stale) {
        try state.publish(
            id: id, owner: "task", revision: 1, content: .init(title: "迟到", primary: .symbol(name: "circle")),
            generation: state.generation, creating: true)
    }
    #expect(throws: IslandError.owner) {
        try state.publish(
            id: id, owner: "other", revision: 3, content: .init(title: "冒用", primary: .symbol(name: "circle")),
            generation: state.generation, creating: true)
    }
    try state.publish(
        id: id, owner: "task", revision: 3, content: .init(title: "新状态", primary: .symbol(name: "circle")),
        generation: state.generation, creating: true)
    #expect(state.activities.count == 1)
}

@Test @MainActor func islandProducerSlotsOwnStableIdentityRevisionCapacityAndRootReset() throws {
    let state = IslandState()
    state.setAvailable(true)
    let content = IslandContent(title: "首次", primary: .symbol(name: "circle"))
    let id = try #require(try state.publishSlot(owner: "producer", content: content))
    let revision = try #require(state.selected?.revision)
    #expect(try state.publishSlot(owner: "producer", content: content) == id)
    #expect(state.selected?.revision == revision)
    try state.publishSlot(owner: "producer", content: nil)
    #expect(state.activities.isEmpty)
    #expect(try state.publishSlot(owner: "producer", content: content) == id)
    #expect(state.selected?.revision == revision + 2)
    for i in 1..<8 { try state.publishSlot(owner: "other-\(i)", content: content) }
    #expect(throws: IslandError.capacity) { try state.publishSlot(owner: "overflow", content: content) }
    #expect(state.activities.count == 8)
    state.setAvailable(false)
    state.setAvailable(true)
    let fresh = try state.publishSlot(owner: "producer", content: content)
    #expect(fresh != id && state.selected?.revision == 1)
}

@Test @MainActor func islandRankingUsesPriorityThenLatestAndReturnsAfterRemoval() throws {
    let state = IslandState()
    state.setAvailable(true)
    let low = try islandItem(state, owner: "low", rank: 10)
    let high = try islandItem(state, owner: "high", rank: 90)
    #expect(state.selectedID == high)
    try state.remove(id: high, owner: "high", revision: 2, generation: state.generation)
    #expect(state.selectedID == low)
    #expect(throws: IslandError.invalid) {
        try IslandContent(title: "无效", primary: .symbol(name: "scope"), expansionID: "").validate()
    }
}
@Test func islandNativeAttentionIsOncePerStageAndBounded() throws {
    let generation = UUID()
    var snapshot = IslandSystemSnapshot(
        generation: generation, activityID: UUID(), title: "任务", subtitle: "执行中", primary: .symbol(name: "scope"),
        tone: "blue",
        updatedAt: .now, attentionID: "task-1")
    var ledger = IslandAttentionLedger()
    #expect(try ledger.take(snapshot))
    snapshot.subtitle = "等待你的操作"
    snapshot.updatedAt = .now
    #expect(try !ledger.take(snapshot))
    snapshot.attentionID = "task-2"
    snapshot.paused = true
    #expect(try !ledger.take(snapshot))
    snapshot.paused = false
    #expect(try ledger.take(snapshot))
    for i in 2..<256 {
        snapshot.attentionID = "stage-\(i)"
        _ = try ledger.take(snapshot)
    }
    snapshot.attentionID = "overflow"
    #expect(throws: IslandError.capacity) { try ledger.take(snapshot) }
    snapshot.generation = UUID()
    #expect(try ledger.take(snapshot))
}
@Test func islandNativeTapAlwaysResumesAppWithoutDestinationNavigation() throws {
    let value = IslandSystemSnapshot(
        generation: UUID(), activityID: UUID(), title: "状态", subtitle: "", primary: .symbol(name: "mic"),
        tone: "blue", updatedAt: Date())
    for destination in ["history", "camera", "bluetooth", "retired-page"] {
        var legacy = try #require(try JSONSerialization.jsonObject(with: value.validatedPayload()) as? [String: Any])
        legacy["destination"] = destination
        legacy["linkTitle"] = "旧跳转按钮"
        let restored = try JSONDecoder().decode(
            IslandSystemSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored == value)
        #expect(restored.navigationURL?.absoluteString == "mobileharness://island")
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: restored.validatedPayload()) as? [String: Any])
        #expect(encoded["destination"] == nil && encoded["linkTitle"] == nil)
    }
}

@Test func islandContentDropsRetiredNavigationMetadataAtDecodeBoundary() throws {
    let current = IslandContent(title: "任务", primary: .symbol(name: "scope"), detail: .init(text: "拍摄照片"))
    var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
    legacy["destination"] = "retired-page"
    legacy["linkTitle"] = "旧跳转按钮"
    let decoded = try JSONDecoder().decode(IslandContent.self, from: JSONSerialization.data(withJSONObject: legacy))
    try decoded.validate()
    #expect(decoded == current)
    let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
    #expect(encoded["destination"] == nil && encoded["linkTitle"] == nil)
}

@Test @MainActor func islandDetailsAreGenericAndOnlyNewStagesAutoExpand() throws {
    let state = IslandState()
    state.setAvailable(true)
    var goal = IslandContent(
        title: "目标", primary: .symbol(name: "scope"), expansionID: "one",
        detail: .init(text: "拍一张照片"))
    let id = try #require(try state.publishSlot(owner: "custom", content: goal))
    #expect(state.expanded && state.compact?.content.primary == .symbol(name: "scope"))
    try state.setExpanded(false)
    goal.subtitle = "进度变化"
    try state.publishSlot(owner: "custom", content: goal)
    #expect(!state.expanded)
    goal.expansionID = "two"
    try state.publishSlot(owner: "custom", content: goal)
    #expect(state.expanded)
    let ordinary = try #require(
        try state.publishSlot(owner: "ordinary", content: .init(title: "声音", primary: .symbol(name: "mic"), rank: 100)))
    #expect(state.compact?.id == ordinary && state.expandedID == id && state.expanded)
    #expect(throws: IslandError.invalid) { try state.setExpanded(true, id: ordinary) }
    try state.publishSlot(owner: "custom", content: nil)
    #expect(!state.expanded && state.detail == nil && state.compact?.id == ordinary)
    #expect(IslandDetail(text: " ").normalized == nil)
    #expect(throws: IslandError.invalid) {
        try IslandDetail(text: String(repeating: "字", count: 321)).validate()
    }
}
@Test @MainActor func islandLocalCompletionRejectsOldGenerationAndRevisionAndSpectrumDoesNotRepublish() throws {
    let state = IslandState()
    state.setAvailable(true)
    try state.publishSlot(
        owner: "voice", content: .init(title: "说话", primary: .symbol(name: "speaker"), secondary: .spectrum))
    let revision = state.localRevision
    state.localCompleted(generation: UUID(), revision: revision)
    #expect(state.localStatus == "pending")
    try state.spectrum(Array(repeating: 0.7, count: 32), active: true, generation: state.generation)
    #expect(state.localRevision == revision && state.bands.count == 32)
    #expect(IslandSpectrum.levels(state.bands, active: true, reduced: false).allSatisfy { abs($0 - 0.7) < 0.001 })
    state.localCompleted(generation: state.generation, revision: revision)
    #expect(state.localStatus == "settled")
    try state.publishSlot(owner: "voice", content: .init(title: "聆听", primary: .symbol(name: "mic")))
    state.localCompleted(generation: state.generation, revision: revision)
    #expect(state.localStatus == "pending")
    state.setAvailable(false)
    #expect(state.localStatus == "detached" && !state.spectrumActive && state.bands.allSatisfy { $0 == 0 })
}
@Test(arguments: [
    CGSize(width: 390, height: 844), CGSize(width: 402, height: 874), CGSize(width: 440, height: 956),
    CGSize(width: 375, height: 812), CGSize(width: 874, height: 402),
])
func islandLocalPlacementHasAlignedSlotsAndNoNeck(_ viewport: CGSize) throws {
    let safeTop = viewport.width == 375 ? 44.0 : viewport.width > viewport.height ? 0 : 62
    let compact = IslandPlacement.resolve(
        viewport: viewport, safeTop: safeTop, safeBottom: 34, expanded: false, detailHeight: 70)
    let expanded = IslandPlacement.resolve(
        viewport: viewport, safeTop: safeTop, safeBottom: 34, expanded: true, detailHeight: 1000)
    #expect(compact.frame.minX >= 16 && compact.frame.maxX <= viewport.width - 16)
    #expect(expanded.frame.minY == compact.frame.minY && expanded.frame.width >= compact.frame.width)
    #expect(expanded.frame.maxY <= viewport.height - 34 - 8)
    #expect(expanded.frame.minY + expanded.contentTop >= (expanded.protected?.maxY ?? CGFloat(safeTop)))
    let left = compact.leadingSlot
    let right = try #require(compact.trailingSlot)
    #expect(abs((left.minX - compact.frame.minX) - (compact.frame.maxX - right.maxX)) < 0.001)
    if let protected = compact.protected {
        #expect(!left.intersects(protected) && !right.intersects(protected))
        #expect(left.minX >= 100 && right.maxX <= viewport.width - 110)
    }
}

@Test func islandCollapseRequiresDeliberateUpwardSwipe() {
    #expect(IslandInteraction.shouldCollapse(translation: CGSize(width: 3, height: -60)))
    #expect(IslandInteraction.shouldCollapse(translation: CGSize(width: 0, height: -36)))
    for movement in [
        CGSize.zero, CGSize(width: 0, height: -35), CGSize(width: 0, height: 90),
        CGSize(width: 80, height: -40), CGSize(width: -80, height: -40),
    ] {
        #expect(!IslandInteraction.shouldCollapse(translation: movement))
    }
}

@Test @MainActor func islandContentControlsExpansionAndKeepsPerActivityPreference() throws {
    let state = IslandState()
    state.setAvailable(true)
    var goal = IslandContent(title: "目标", primary: .symbol(name: "scope"), rank: 50, detail: .init(text: "拍照"))
    let goalID = try #require(try state.publishSlot(owner: "goal", content: goal))
    #expect(state.expanded && state.detail?.text == "拍照")
    try state.setExpanded(false)
    goal.detail?.text = "拍照并保存"
    try state.publishSlot(owner: "goal", content: goal)
    #expect(!state.expanded && state.detailActivity?.content.detail?.text == "拍照并保存")
    let other = try #require(
        try state.publishSlot(owner: "camera", content: .init(title: "录像", primary: .symbol(name: "video"), rank: 90)))
    #expect(state.compact?.id == other && state.detail == nil && !state.expanded)
    #expect(state.detailActivity?.id == goalID)
    try state.setExpanded(true)
    #expect(state.expanded && state.headerActivity?.id == other)
    try state.setExpanded(false)
    try state.publishSlot(owner: "camera", content: nil)
    #expect(state.compact?.id == goalID && !state.expanded)
    try state.setExpanded(true)
    try state.publishSlot(owner: "camera", content: .init(title: "录像", primary: .symbol(name: "video"), rank: 90))
    try state.publishSlot(owner: "camera", content: nil)
    #expect(state.expanded && state.compact?.content.primary == goal.primary)
    goal.detail = .init(text: "   ")
    try state.publishSlot(owner: "goal", content: goal)
    #expect(!state.expanded && state.detailActivity == nil)
    goal.detail = .init(text: "新的内容")
    try state.publishSlot(owner: "goal", content: goal)
    #expect(state.expanded)
}

@Test func islandNewIndicatorWireAndLegacyDecodeHaveOneCanonicalForm() throws {
    let old = Data(#"{"title":"目标","symbol":"scope","trailing":"loading","detail":{"symbol":"flag","text":"拍照"}}"#.utf8)
    let value = try JSONDecoder().decode(IslandContent.self, from: old)
    #expect(value.primary == .symbol(name: "scope") && value.secondary == .loading)
    #expect(value.detail?.text == "拍照")
    let canonical = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    #expect(canonical["symbol"] == nil && canonical["trailing"] == nil && canonical["primary"] != nil)
    for indicator in [
        IslandIndicator.symbol(name: "mic", effect: .pulse), .symbol(name: "bell", effect: .bounce),
        .symbol(name: "wifi", effect: .variableColor), .loading, .spectrum, .progress(0.7),
        .elapsed(startedAt: Date(timeIntervalSinceReferenceDate: 12345)),
    ] {
        #expect(try JSONDecoder().decode(IslandIndicator.self, from: JSONEncoder().encode(indicator)) == indicator)
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(IslandContent.self, from: Data(#"{"title":"missing indicator"}"#.utf8))
    }
    #expect(!IslandIndicator.elapsed(startedAt: Date(timeIntervalSinceReferenceDate: .nan)).isValid)
    #expect(!IslandIndicator.progress(.nan).isValid)
    #expect(!IslandIndicator.progress(1.1).isValid)
    #expect(!IslandIndicator.symbol(name: " ").isValid)
}

private func islandTestImage() throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: 512, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let target = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(target, image, nil)
    try #require(CGImageDestinationFinalize(target))
    return data as Data
}
@Test @MainActor func islandThumbnailRegistrationBindingReplacementAndCapacity() async throws {
    let state = IslandState()
    state.setAvailable(true)
    let data = try islandTestImage()
    let gen = state.generation
    let image = try await state.registerThumbnail(data, owner: "image", generation: gen)
    let decoded = try #require(state.thumbnailData(image))
    let source = try #require(CGImageSourceCreateWithData(decoded as CFData, nil))
    let bitmap = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(bitmap.width == 256 && bitmap.height == 64)
    #expect(throws: IslandError.owner) { try state.releaseThumbnail(image, owner: "other", generation: gen) }
    var content = IslandContent(title: "图片", primary: .symbol(name: "photo"), detail: .init(thumbnail: image))
    let id = UUID()
    #expect(throws: IslandError.owner) {
        try state.publish(id: id, owner: "other", revision: 1, content: content, generation: gen, creating: true)
    }
    try state.publish(id: id, owner: "image", revision: 1, content: content, generation: gen, creating: true)
    #expect(state.expanded && state.detail?.text == nil && state.detail?.thumbnail == image)
    #expect(throws: IslandError.busy) { try state.releaseThumbnail(image, owner: "image", generation: gen) }
    #expect(throws: IslandError.busy) {
        try state.publish(id: UUID(), owner: "image", revision: 1, content: content, generation: gen, creating: true)
    }
    try state.setExpanded(false)
    let replacement = try await state.registerThumbnail(data, owner: "image", generation: gen)
    content.detail = .init(text: "说明", thumbnail: replacement)
    try state.publish(id: id, owner: "image", revision: 2, content: content, generation: gen, creating: false)
    #expect(!state.expanded && state.thumbnailData(image) == nil && state.thumbnailData(replacement) != nil)
    try state.setExpanded(true)
    #expect(state.detail?.text == "说明" && state.detail?.thumbnail == replacement)
    try state.remove(id: id, owner: "image", revision: 3, generation: gen)
    #expect(state.thumbnailData(replacement) == nil)
    var retained: [UUID] = []
    for _ in 0..<8 { retained.append(try await state.registerThumbnail(data, owner: "image", generation: gen)) }
    await #expect(throws: IslandError.capacity) {
        try await state.registerThumbnail(data, owner: "image", generation: gen)
    }
    try state.releaseThumbnail(retained[0], owner: "image", generation: gen)
    await #expect(throws: IslandError.invalid) {
        try await state.registerThumbnail(Data("invalid".utf8), owner: "image", generation: gen)
    }
    #expect(throws: IslandError.missing) {
        try state.publish(id: UUID(), owner: "image", revision: 1, content: content, generation: gen, creating: true)
    }
    state.setAvailable(false)
    #expect(retained.allSatisfy { state.thumbnailData($0) == nil })
    state.setAvailable(true)
    await #expect(throws: IslandError.stale) {
        try await state.registerThumbnail(data, owner: "image", generation: gen)
    }
    let registration = Task { try await state.registerThumbnail(data, owner: "image", generation: state.generation) }
    registration.cancel()
    await #expect(throws: CancellationError.self) { try await registration.value }
    await state.stop()
}

@Test @MainActor func islandCompactHeightAndHousingDoNotChangeWhenAddingIndicators() throws {
    let viewport = CGSize(width: 402, height: 874)
    let single = IslandPlacement.resolve(
        viewport: viewport, safeTop: 62, safeBottom: 34, expanded: false,
        detailHeight: 0, hasSecondary: false)
    let pair = IslandPlacement.resolve(
        viewport: viewport, safeTop: 62, safeBottom: 34, expanded: false,
        detailHeight: 0, hasSecondary: true)
    let housing = try #require(pair.protected)
    #expect(single.protected == pair.protected)
    #expect(abs(housing.midX - viewport.width / 2) < 0.001)
    #expect(abs(pair.compact.minY - 14) < 0.001)
    #expect(abs(pair.compact.height - 110.0 / 3) < 0.001)
    #expect(single.compact.minY == housing.minY && pair.compact.minY == housing.minY)
    #expect(single.compact.height == housing.height && pair.compact.height == housing.height)
    #expect(single.corner == housing.height / 2 && pair.corner == housing.height / 2)
    #expect(abs(pair.leadingSlot.maxX - housing.minX) < 0.001)
    #expect(abs(try #require(pair.trailingSlot).minX - housing.maxX) < 0.001)
    #expect(pair.leadingSlot.midY == housing.midY && pair.trailingSlot?.midY == housing.midY)
    #expect(abs(pair.leadingSlot.midX * 3 - 382) < 0.001)
    #expect(abs(try #require(pair.trailingSlot).midX * 3 - 824) < 0.001)
    #expect(single.trailingSlot == nil && abs(single.compact.maxX - housing.maxX) < 0.001)
    #expect(abs(pair.compact.width - 185.333333) < 0.001)
    #expect(abs(pair.compact.width - single.compact.width - 30) < 0.001)
    #expect(abs(pair.leadingSlot.minX - pair.compact.minX - 8) < 0.001)
    let expanded = IslandPlacement.resolve(
        viewport: viewport, safeTop: 62, safeBottom: 34, expanded: true,
        detailHeight: 100, hasSecondary: false)
    #expect(expanded.compact == single.compact && expanded.protected == single.protected)
    #expect(expanded.frame.height > single.compact.height)
}

@Test @MainActor func islandCollapsedDetailReopensFromCenterAndBothWings() throws {
    let state = IslandState()
    state.setAvailable(true)
    let content = IslandContent(
        title: "目标", primary: .symbol(name: "scope"), secondary: .loading,
        detail: .init(text: "拍照并等待保存、忽略或重拍"))
    _ = try state.publishSlot(owner: "goal", content: content)
    let placement = IslandPlacement.resolve(
        viewport: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34,
        expanded: false, detailHeight: 44)
    let centers = [placement.leadingSlot.midX, placement.compact.midX, try #require(placement.trailingSlot).midX]
    for x in centers {
        try state.setExpanded(false)
        #expect(state.detail == nil && state.detailActivity?.content.detail == content.detail)
        #expect(
            IslandInteraction.contains(
                CGPoint(x: x, y: placement.compact.midY), frame: placement.frame, corner: placement.corner))
        try state.setExpanded(true)
        #expect(state.detail == content.detail)
    }
    #expect(!IslandInteraction.contains(placement.frame.origin, frame: placement.frame, corner: placement.corner))
    #expect(!IslandInteraction.contains(CGPoint(x: 0, y: 100), frame: placement.frame, corner: placement.corner))
}

@Test func islandTimerAddsWidthWithoutChangingHeightOrHousingAlignment() throws {
    let start = Date(timeIntervalSinceReferenceDate: 12345)
    let regular = IslandPlacement.resolve(
        viewport: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, expanded: false, detailHeight: 0)
    let timed = IslandPlacement.resolve(
        viewport: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, expanded: false, detailHeight: 0,
        secondaryWidth: IslandIndicator.elapsed(startedAt: start).compactWidth)
    #expect(timed.compact.height == regular.compact.height)
    #expect(timed.compact.minY == regular.compact.minY && timed.protected == regular.protected)
    let shield = try #require(timed.protected)
    #expect(timed.leadingSlot.maxX == shield.minX)
    #expect(timed.trailingSlot?.minX == shield.maxX)
    #expect(timed.trailingSlot?.width == 44)
    #expect(abs(timed.compact.maxX - (try #require(timed.trailingSlot)).maxX - 8) < 0.001)
}

@Test func islandSystemStatusesMoveOutBeforeHidingInnermostNetwork() throws {
    let shell = CGRect(x: 16, y: 14, width: 370, height: 110.0 / 3)
    let row = shell
    let normal = IslandStatusBarLayout.resolve(
        shell: shell, occupied: CGRect(x: 110, y: 14, width: 160, height: 37), row: row)
    #expect(normal.time?.minX == 32)
    #expect(normal.battery?.maxX == 370)
    let compressed = IslandStatusBarLayout.resolve(
        shell: shell, occupied: CGRect(x: 80, y: 14, width: 240, height: 37), row: row)
    #expect(compressed.time?.minX == 26)
    #expect(compressed.network != nil && compressed.battery != nil)
    #expect(try #require(compressed.battery).maxX == 376)
    let networkHidden = IslandStatusBarLayout.resolve(
        shell: shell, occupied: CGRect(x: 80, y: 14, width: 252, height: 37), row: row)
    #expect(networkHidden.network == nil && networkHidden.battery != nil)
    let noRoom = IslandStatusBarLayout.resolve(
        shell: shell, occupied: CGRect(x: 65, y: 14, width: 285, height: 37), row: row)
    #expect(noRoom.time == nil && noRoom.network == nil && noRoom.battery == nil)
}

@Test(arguments: [CGFloat(240), 375, 390, 402, 440, 874])
func islandSystemStatusesNeverOverlapBusinessOrLeaveViewport(_ width: CGFloat) {
    for left in stride(from: CGFloat(0), through: width / 2, by: 10) {
        let business = CGRect(x: left, y: 14, width: width - left * 2, height: 37)
        let layout = IslandStatusBarLayout.resolve(
            shell: CGRect(x: 16, y: 14, width: width - 32, height: 37), occupied: business, row: business)
        for frame in [layout.time, layout.network, layout.battery].compactMap({ $0 }) {
            #expect(frame.minX >= 26 && frame.maxX <= width - 26)
            #expect(!frame.intersects(business))
            #expect(frame.midY == business.midY)
        }
    }
}

@Test @MainActor func islandSystemStatusLifetimeFollowsActualLocalMount() throws {
    var reads = 0
    let state = IslandState(systemStatus: {
        reads += 1
        return .init(network: .wifi, batteryLevel: 0.85)
    })
    state.setAvailable(true)
    try state.publishSlot(owner: "voice", content: .init(title: "Listening", primary: .symbol(name: "mic")))
    #expect(!state.replacesSystemStatusBar && reads == 0)
    state.localMounted()
    state.localMounted()
    #expect(state.replacesSystemStatusBar && reads == 1)
    #expect(state.statusBar.value.batteryPercent == 85)
    state.setSceneActive(false)
    state.statusBar.refresh()
    #expect(!state.replacesSystemStatusBar && !state.statusBar.active && reads == 1)
    state.setSceneActive(true)
    #expect(!state.replacesSystemStatusBar)
    state.localMounted()
    #expect(reads == 2 && state.replacesSystemStatusBar)
    state.setAvailable(false)
    #expect(!state.replacesSystemStatusBar && !state.statusBar.active)
    state.localMounted()
    #expect(!state.replacesSystemStatusBar && reads == 2)
}

@Test @MainActor func islandUnknownSystemStatusDoesNotFabricateBatteryOrKeepStaleFacts() {
    var fails = false
    let failures = Mutex(0)
    let status = IslandStatusBarState(
        read: {
            if fails { throw UIContainerError.unavailable }
            return .init(network: .wifi, batteryLevel: 0.5)
        }, onFailure: { _, _, _ in failures.withLock { $0 += 1 } })
    status.start()
    #expect(status.value.batteryPercent == 50 && !status.failed)
    fails = true
    status.refresh()
    #expect(status.value.batteryPercent == nil && status.value.network == .unknown && status.failed)
    status.refresh()
    #expect(failures.withLock { $0 } == 1)
    fails = false
    status.refresh()
    #expect(status.value.batteryPercent == 50 && !status.failed)
    fails = true
    status.refresh()
    #expect(failures.withLock { $0 } == 2)
    status.stop()
    status.refresh()
    #expect(status.value.batteryPercent == nil && !status.active)
    for level in [Double.nan, .infinity, -0.1, 1.1] {
        #expect(IslandDeviceStatus(batteryLevel: level).batteryPercent == nil)
    }
}

@Test func islandSystemAndBusinessShareOneShellAndCenterline() throws {
    let viewport = CGSize(width: 402, height: 874)
    for expanded in [false, true] {
        let placement = IslandPlacement.resolve(
            viewport: viewport, safeTop: 62, safeBottom: 34, expanded: expanded, detailHeight: 80,
            secondaryWidth: 44)
        let occupied = placement.header
        let status = IslandStatusBarLayout.resolve(shell: placement.frame, occupied: occupied, row: placement.header)
        let time = try #require(status.time)
        let battery = try #require(status.battery)
        let network = try #require(status.network)
        for frame in [time, battery, network, placement.leadingSlot] {
            #expect(placement.frame.contains(frame))
            #expect(abs(frame.midY - placement.header.midY) < 0.001)
        }
        #expect(abs(time.minX - placement.frame.minX - (placement.frame.maxX - battery.maxX)) < 0.001)
        #expect(battery.size == CGSize(width: 28, height: 14))
        #expect(placement.frame.width == 370)
        if !expanded { #expect(placement.frame.height == IslandCompactMetrics.height) }
        let source = try #require(placement.protected)
        for fraction in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            let shell = CGRect(
                x: source.minX + (placement.frame.minX - source.minX) * fraction,
                y: source.minY, width: source.width + (placement.frame.width - source.width) * fraction,
                height: source.height + (placement.frame.height - source.height) * fraction)
            let content = IslandStatusBarLayout.contentFrame(viewport: viewport, shell: shell)
            #expect(abs(shell.minX + content.minX) < 0.001)
            #expect(abs(shell.minY + content.minY) < 0.001)
        }
    }
}

@Test func islandBatteryFillReflectsLevelWithoutChangingFootprint() {
    let size = CGSize(width: 28, height: 14)
    let empty = IslandBatteryGeometry.resolve(size: size, level: 0)
    let half = IslandBatteryGeometry.resolve(size: size, level: 0.5)
    let full = IslandBatteryGeometry.resolve(size: size, level: 1)
    #expect(empty.body == half.body && half.body == full.body)
    #expect(empty.fill.width == 0 && half.fill.width * 2 == full.fill.width)
    #expect(full.body.contains(full.fill))
    #expect(!full.body.intersects(full.terminal))
    #expect(CGRect(origin: .zero, size: size).contains(full.terminal))
    #expect(IslandBatteryGeometry.resolve(size: size, level: nil).fill.width == 0)
    #expect(IslandBatteryGeometry.resolve(size: size, level: .nan).fill.width == 0)
}

@Test func islandExpandedHeaderMovesTogetherAndDetailClosesTheGap() throws {
    for width in [390.0, 402, 430] {
        let compact = IslandPlacement.resolve(
            viewport: .init(width: width, height: 874), safeTop: 62, safeBottom: 34,
            expanded: false, detailHeight: 44, secondaryWidth: 44)
        let expanded = IslandPlacement.resolve(
            viewport: .init(width: width, height: 874), safeTop: 62, safeBottom: 34,
            expanded: true, detailHeight: 44, secondaryWidth: 44)
        #expect(expanded.protected == compact.protected)
        #expect(expanded.header.minX == compact.header.minX)
        #expect(expanded.header.width == compact.header.width)
        #expect(abs(expanded.header.midY - compact.header.midY - 6) < 0.001)
        #expect(abs(expanded.frame.minY + expanded.contentTop - expanded.header.maxY - 4) < 0.001)
        #expect(abs(expanded.frame.height - expanded.contentTop - 44 - 18) < 0.001)
        let status = IslandStatusBarLayout.resolve(
            shell: expanded.frame, occupied: expanded.header, row: expanded.header)
        for rect in [status.time, status.network, status.battery].compactMap({ $0 }) {
            #expect(!rect.intersects(expanded.header))
            #expect(abs(rect.midY - expanded.leadingSlot.midY) < 0.001)
        }
    }
}

@Test @MainActor func islandTaskDetailSurvivesEveryTransientStatusAndIndependentEnd() throws {
    let state = IslandState()
    state.setAvailable(true)
    let goal = IslandContent(title: "目标", primary: .symbol(name: "scope"), rank: 85, detail: .init(text: "拍摄窗边的植物"))
    let goalID = try #require(try state.publishSlot(owner: "arbitrary-detail-owner", content: goal))
    #expect(state.expanded && state.headerActivity == nil)
    for status in [
        IslandContent(
            title: "聆听", primary: .symbol(name: "mic.fill"), rank: 60, secondary: .elapsed(startedAt: Date())),
        IslandContent(title: "说话", primary: .symbol(name: "speaker.wave.2.fill"), rank: 65, secondary: .spectrum),
        IslandContent(title: "拍摄", primary: .symbol(name: "camera.fill"), rank: 100, secondary: .loading),
        IslandContent(title: "等待", primary: .symbol(name: "sparkles"), rank: 55, secondary: .loading),
    ] {
        try state.publishSlot(owner: "arbitrary-status-owner", content: status)
        #expect(state.expanded && state.expandedID == goalID && state.detail?.text == goal.detail?.text)
        #expect(state.headerActivity?.content == status && state.detailActivity?.content.primary == goal.primary)
        try state.setExpanded(false)
        try state.publishSlot(owner: "arbitrary-status-owner", content: status)
        #expect(!state.expanded && state.detailActivity?.content.detail == goal.detail)
        try state.setExpanded(true)
    }
    try state.publishSlot(owner: "arbitrary-status-owner", content: nil)
    #expect(state.expanded && state.headerActivity == nil && state.detailActivity?.id == goalID)
    try state.setExpanded(false)
    #expect(state.headerActivity?.id == goalID)
    try state.setExpanded(true)
    try state.publishSlot(
        owner: "arbitrary-status-owner", content: .init(title: "聆听", primary: .symbol(name: "mic.fill")))
    try state.publishSlot(owner: "arbitrary-detail-owner", content: nil)
    #expect(!state.expanded && state.detailActivity == nil && state.headerActivity?.content.title == "聆听")
    #expect(throws: IslandError.invalid) { try state.setExpanded(true) }
}

@Test @MainActor func islandLocalReservationFollowsLayoutAndClearsOnDetach() {
    let state = IslandState()
    let compact = CGRect(x: 16, y: 14, width: 370, height: IslandCompactMetrics.height)
    state.reserveLocalFrame(compact)
    #expect(state.localFrame == nil)
    state.setAvailable(true)
    let revision = state.localRevision
    state.reserveLocalFrame(compact)
    #expect(state.localFrame == compact && state.localRevision == revision)
    let expanded = CGRect(x: 16, y: 14, width: 370, height: 110)
    state.reserveLocalFrame(expanded)
    #expect(state.localFrame == expanded)
    state.setSceneActive(false)
    #expect(state.localFrame == nil)
    state.reserveLocalFrame(expanded)
    #expect(state.localFrame == nil)
}

@Test func islandBackgroundContractsWithoutMovingSystemStatus() throws {
    let viewport = CGSize(width: 402, height: 874)
    let compact = IslandPlacement.resolve(
        viewport: viewport, safeTop: 62, safeBottom: 34, expanded: false, detailHeight: 44,
        secondaryWidth: 44)
    let expanded = IslandPlacement.resolve(
        viewport: viewport, safeTop: 62, safeBottom: 34, expanded: true, detailHeight: 44,
        secondaryWidth: 44)
    #expect(compact.background == compact.compact)
    #expect(compact.background.height == IslandCompactMetrics.height)
    #expect(expanded.background == expanded.frame)
    #expect(compact.frame.width == expanded.frame.width)
    let status = IslandStatusBarLayout.resolve(
        shell: compact.frame, occupied: compact.header, row: compact.header)
    let time = try #require(status.time)
    let battery = try #require(status.battery)
    #expect(!compact.background.intersects(time))
    #expect(!compact.background.intersects(battery))
    #expect(compact.frame.contains(time) && compact.frame.contains(battery))
    #expect(
        !IslandInteraction.contains(
            CGPoint(x: time.midX, y: time.midY), frame: compact.background, corner: compact.corner))
    #expect(
        IslandInteraction.contains(
            CGPoint(x: compact.compact.midX, y: compact.compact.midY),
            frame: compact.background, corner: compact.corner))
}
