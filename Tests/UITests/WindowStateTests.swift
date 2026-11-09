import Foundation
import ImageIO
import Testing

@testable import UI

@MainActor private func windowEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw WindowError.unavailable }
        await Task.yield()
    }
}
@MainActor private func acknowledge(_ state: WindowState, _ id: UUID) throws {
    let item = try state.find(id)
    state.complete(id, revision: item.revision, generation: state.generation, success: true)
}
@MainActor private func presentFixture(
    _ state: WindowState, _ name: String = "fixture", title: String? = nil, icon: WindowIcon? = nil
) async throws -> UUID {
    let opening = Task {
        try await state.present(content: .init(rawValue: name, singleInstance: true), title: title ?? name, icon: icon)
    }
    try await windowEventually { state.windows.contains { $0.content == name } }
    let id = try #require(state.windows.first { $0.content == name }?.id)
    try acknowledge(state, id)
    return try await opening.value
}
@Test @MainActor func windowCapacityFocusAndStableIdentity() async throws {
    let state = WindowState()
    state.layout(width: 390, height: 750)
    state.setAvailable(true)
    let first = try await presentFixture(state, "one")
    for index in 1..<WindowState.maximumWindows {
        _ = try await presentFixture(state, "window-\(index)")
    }
    #expect(state.windows.count == WindowState.maximumWindows)
    await #expect(throws: WindowError.capacity) {
        try await state.present(content: .init(rawValue: "overflow"), title: "overflow")
    }
    #expect(
        try await state.present(content: .init(rawValue: "one", singleInstance: true), title: "unchanged") == first)
    #expect(state.focusedID == first && state.windows.last?.id == first)
    await state.stop()
}
@Test @MainActor func windowNormalMaximizedAndCardPositionsStayIndependent() async throws {
    let state = WindowState()
    state.layout(width: 390, height: 750)
    state.setAvailable(true)
    let id = try await presentFixture(state)
    #expect(try state.find(id).normal == .init(x: 16, y: 125, width: 358, height: 500))
    try state.move(id, x: 80, y: 95)
    let normal = try state.find(id).normal
    let color = try state.find(id).color
    for command in [WindowCommand.maximize, .minimize] {
        let revision = try state.find(id).revision
        let change = Task { try await state.change(id, command: command) }
        try await windowEventually { (try? state.find(id).revision) != revision }
        try acknowledge(state, id)
        try await change.value
    }
    try state.move(id, x: -100, y: 900)
    #expect(try state.find(id).card.x == 0)
    #expect(try state.find(id).card.y == 702)
    for expected in [WindowMode.maximized, .normal] {
        let revision = try state.find(id).revision
        let change = Task { try await state.change(id, command: .restore) }
        try await windowEventually { (try? state.find(id).revision) != revision }
        try acknowledge(state, id)
        try await change.value
        #expect(try state.find(id).mode == expected)
    }
    #expect(try state.find(id).normal == normal)
    #expect(try state.find(id).color == color)
    #expect(try state.find(id).card.x == 0)
    state.layout(width: 750, height: 390)
    let frame = state.frame(try state.find(id))
    #expect(frame.x >= 0 && frame.x + frame.width <= 750 && frame.y + 52 <= 390)
    await state.stop()
}
@Test @MainActor func windowDragKeepsBothTitleBarControlsInsideSafeArea() async throws {
    let state = WindowState()
    state.layout(width: 390, height: 750)
    state.setAvailable(true)
    let id = try await presentFixture(state)
    for x in [-500.0, 500.0] {
        try state.drag(id, x: x, y: 900)
        let during = state.frame(try state.find(id))
        #expect(during.x >= 0 && during.x + during.width <= 390)
        #expect(during.y + 52 <= 750)
        state.endDrag(id)
        #expect(state.frame(try state.find(id)) == during)
    }
    try state.move(id, x: 1000, y: 0)
    let moved = state.frame(try state.find(id))
    #expect(moved.x + moved.width <= 390)
    state.layout(width: 320, height: 640)
    let rotated = state.frame(try state.find(id))
    #expect(rotated.x >= 0 && rotated.x + rotated.width <= 320)
    await state.stop()
}

@Test @MainActor func windowReplacedTransitionRejectsLateReceiptAndBackgroundUnblocks() async throws {
    let state = WindowState()
    state.layout(width: 390, height: 750)
    state.setAvailable(true)
    let id = try await presentFixture(state)
    let generation = state.generation
    let first = Task { try await state.change(id, command: .minimize) }
    try await windowEventually { (try? state.find(id).mode) == .minimized }
    let staleRevision = try state.find(id).revision
    let second = Task { try await state.change(id, command: .maximize) }
    try await windowEventually { (try? state.find(id).mode) == .maximized }
    await #expect(throws: WindowError.self) { try await first.value }
    state.complete(id, revision: staleRevision, generation: generation, success: true)
    #expect(try state.find(id).phase == .changing)
    state.setAvailable(false)
    await #expect(throws: WindowError.self) { try await second.value }
    state.setAvailable(true)
    state.complete(id, revision: staleRevision, generation: generation, success: true)
    #expect(try state.find(id).mode == .maximized)
    await state.stop()
}
@Test @MainActor func windowCloseDecisionKeepsIdentityAndCancellationReleasesPrompt() async throws {
    let state = WindowState()
    state.layout(width: 390, height: 750)
    state.setAvailable(true)
    let id = try await presentFixture(state)
    let prompt = WindowPrompt(title: "fixture", choices: [.init(id: "cancel", title: "Cancel")])
    let answer = Task { try await state.ask(id, prompt: prompt) }
    try await windowEventually { (try? state.find(id).prompt) != nil }
    state.answer(id, promptID: try #require(state.find(id).prompt?.id), choice: "cancel")
    #expect(try await answer.value == "cancel")
    #expect(try state.find(id).prompt == nil)
    let cancelled = Task { try await state.ask(id, prompt: prompt) }
    try await windowEventually { (try? state.find(id).prompt) != nil }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try state.find(id).prompt == nil)
    await state.stop()
}
@Test func windowGeometryRetainsControlsAndRejectsNaNAtAdmission() async throws {
    let geometry = WindowGeometry(x: -500, y: 900, width: 358, height: 500).constrained(
        width: 390, height: 750, card: false)
    #expect(geometry.x == 0 && geometry.y == 698)
}

@Test @MainActor func cameraLensFollowsVisibleSurfaceAndCompletedTransitions() async throws {
    let windows = WindowState()
    windows.layout(width: 390, height: 750)
    windows.setAvailable(true)
    let camera = CameraState()
    camera.windows = windows
    camera.faceVisible = true
    camera.present(.perceptionEnabled(true))
    camera.present(.isVisible(true))
    #expect(camera.canSwitch(.perception))
    let opening = Task { try await windows.present(content: .camera, title: "Camera") }
    try await windowEventually { !windows.windows.isEmpty }
    let id = try #require(windows.windows.first?.id)
    #expect(camera.lensOwner == nil)
    try acknowledge(windows, id)
    _ = try await opening.value
    camera.present(.isEnabled(true))
    #expect(camera.canSwitch(.capture))
    #expect(!camera.canSwitch(.perception))
    for command in [WindowCommand.minimize, .restore] {
        let before = try windows.find(id).revision
        let change = Task { try await windows.change(id, command: command) }
        try await windowEventually { (try? windows.find(id).revision) != before }
        #expect(camera.lensOwner == nil)
        windows.complete(id, revision: before, generation: windows.generation, success: true)
        #expect(camera.lensOwner == nil)
        try acknowledge(windows, id)
        try await change.value
        #expect(camera.lensOwner == (command == .minimize ? .perception : .capture))
        #expect(camera.isEnabled && camera.isVisible)
    }
    let covering = try await presentFixture(windows, "opaque")
    #expect(camera.lensOwner == .perception)  // background outside both windows is still visible
    try windows.focus(id)
    #expect(camera.lensOwner == .capture)
    try windows.focus(covering)
    camera.faceVisible = false
    #expect(camera.lensOwner == nil)
    camera.faceVisible = true
    let maximize = Task { try await windows.change(covering, command: .maximize) }
    try await windowEventually { (try? windows.find(covering).mode) == .maximized }
    try acknowledge(windows, covering)
    try await maximize.value
    #expect(camera.lensOwner == nil)
    #expect(camera.isEnabled && camera.perceptionEnabled)  // coverage does not change demand
    windows.setAvailable(false)
    #expect(!camera.canSwitch(.capture) && !camera.canSwitch(.perception))
    await windows.stop()
}

@Test @MainActor func cameraLensHandoffBlocksBothSourcesAndDoesNotRestoreOldFacing() {
    let camera = CameraState()
    camera.faceVisible = true
    camera.present(.perceptionEnabled(true))
    camera.present(.isVisible(true))
    camera.present(.facing(.back))
    camera.present(.lensHandoff(true))
    #expect(camera.lensOwner == nil)
    camera.present(.lensHandoff(false))
    #expect(camera.canSwitch(.perception))
    #expect(camera.facing == .back)
    camera.faceVisible = false
    #expect(camera.lensOwner == nil)
}

@Test(arguments: [(390.0, 750.0), (750.0, 390.0), (1024.0, 1366.0)])
func imageWindowFitsSafeAreaWithoutChangingImageRatio(_ size: (Double, Double)) {
    let frame = WindowSizing.image(aspect: 3.0 / 4.0, controlsHeight: 96).initial(width: size.0, height: size.1)
    #expect(abs(frame.width / (frame.height - 148) - 0.75) < 0.00001)
    #expect(frame.x >= 16 && frame.y >= 0)
    #expect(frame.x + frame.width <= size.0 - 16 && frame.y + frame.height <= size.1)
    #expect(abs(frame.x - (size.0 - frame.width) / 2) < 0.00001)
}

@Test @MainActor func failedWindowReceiptCannotGrantLensAuthority() async throws {
    let windows = WindowState()
    windows.layout(width: 390, height: 750)
    windows.setAvailable(true)
    let camera = CameraState()
    camera.windows = windows
    camera.faceVisible = true
    camera.present(.perceptionEnabled(true))
    let id = try await presentFixture(windows, "camera")
    let revision = try windows.find(id).revision
    let minimize = Task { try await windows.change(id, command: .minimize) }
    try await windowEventually { (try? windows.find(id).revision) != revision }
    let pending = try windows.find(id)
    windows.complete(id, revision: pending.revision, generation: windows.generation, success: false)
    await #expect(throws: WindowError.self) { try await minimize.value }
    #expect(camera.lensOwner == nil)
    await windows.stop()
}

@Test func portraitCameraDefaultClearsOrdinaryExpandedIslandWithoutCropping() {
    let frame = WindowSizing.image(aspect: 3.0 / 4.0, controlsHeight: 140).initial(width: 402, height: 778)
    let island = IslandPlacement.resolve(
        viewport: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34,
        expanded: true, detailHeight: 44)
    #expect(frame.y + 62 >= island.frame.maxY + 12)
    #expect(frame.y + frame.height <= 778)
    #expect(abs(frame.width / (frame.height - 192) - 0.75) < 0.00001)
    #expect(WindowSizing.standard.initial(width: 402, height: 778) == WindowGeometry.initial(width: 402, height: 778))
}

@Test(arguments: [
    (CGRect(x: 0, y: 0, width: 402, height: 874), CGRect(x: 0, y: 62, width: 402, height: 778)),
    (CGRect(x: 0, y: 0, width: 874, height: 402), CGRect(x: 62, y: 0, width: 750, height: 381)),
])
func windowMaximizedShellTouchesScreenEdgesAndReservesOnlyTop(_ viewport: CGRect, _ safe: CGRect) {
    for boundary: Double? in [nil, 51, 142] {
        let frame = WindowGeometry.maximized(viewport: viewport, safe: safe, topBoundary: boundary)
        #expect(frame.x + Double(safe.minX) == Double(viewport.minX))
        #expect(frame.width == Double(viewport.width))
        #expect(frame.y + Double(safe.minY) == boundary.map { $0 + 4 } ?? Double(safe.minY))
        #expect(frame.y + Double(safe.minY) + frame.height == Double(viewport.maxY))
    }
}

@Test @MainActor func windowIslandReservationKeepsNormalAndCardAndMaximizedRestore() async throws {
    let state = WindowState()
    let viewport = CGRect(x: 0, y: 0, width: 402, height: 874)
    let safe = CGRect(x: 0, y: 62, width: 402, height: 778)
    let compact = WindowGeometry.maximized(viewport: viewport, safe: safe, topBoundary: 51)
    let expanded = WindowGeometry.maximized(viewport: viewport, safe: safe, topBoundary: 142)
    state.layout(width: safe.width, height: safe.height, maximized: compact)
    state.setAvailable(true)
    let id = try await presentFixture(state)
    try state.move(id, x: 12, y: 160)
    let normal = try state.find(id).normal
    let card = try state.find(id).card
    for command in [WindowCommand.maximize, .minimize, .restore, .restore] {
        let revision = try state.find(id).revision
        let change = Task { try await state.change(id, command: command) }
        try await windowEventually { (try? state.find(id).revision) != revision }
        try acknowledge(state, id)
        try await change.value
        if command == .maximize {
            #expect(state.frame(try state.find(id)) == compact)
            state.layout(width: safe.width, height: safe.height, maximized: expanded)
            #expect(state.frame(try state.find(id)) == expanded)
        }
        #expect(try state.find(id).normal == normal && state.find(id).card == card)
        if try state.find(id).mode == .maximized { #expect(state.frame(try state.find(id)) == expanded) }
    }
    #expect(try state.find(id).mode == .normal && state.frame(state.find(id)) == normal)
    await state.stop()
}

@Test @MainActor func navigationCoversWindowWithoutChangingIdentityGeometryOrMode() async throws {
    let root = UIContainer()
    try root.start()
    let state = root.windows
    state.layout(width: 390, height: 750)
    let id = try await presentFixture(state, WindowContent.camera.rawValue)
    try state.move(id, x: 20, y: 100)
    let original = try state.find(id)
    let camera = CameraState()
    camera.windows = state
    camera.faceVisible = true
    camera.perceptionEnabled = true
    #expect(camera.lensOwner == .capture)
    root.navigation.state.show(.settings)
    #expect(state.isCovered(id) && !state.hasVisibleContent(id, topInset: 52, bottomInset: 140))
    #expect(!state.hasVisibleBackground() && camera.lensOwner == nil)
    root.navigation.state.show(.album)
    #expect(state.isCovered(id))
    root.navigation.state.show(nil)
    let restored = try state.find(id)
    #expect(restored.id == original.id && restored.mode == original.mode && restored.normal == original.normal)
    #expect(restored.revision == original.revision && restored.presentationConfirmed)
    #expect(!state.isCovered(id) && camera.lensOwner == .capture)
    await root.stop()
}

@Test @MainActor func windowCardsFitTitlesAndCapLongTextWithinNarrowViewports() async throws {
    let state = WindowState()
    state.layout(width: 390, height: 750)
    state.setAvailable(true)
    let short = try await presentFixture(state, "camera", title: "相机", icon: .system(name: "camera.fill"))
    let web = try await presentFixture(state, "web", title: "网页与绘图", icon: .system(name: "globe"))
    let long = try await presentFixture(state, "long", title: String(repeating: "长标题", count: 50), icon: .emoji("🎨"))
    let mixed = try await presentFixture(state, "mixed", title: "Sketch 👩🏽‍🎨 草稿")
    #expect(try state.find(short).card.width < state.find(web).card.width)
    #expect(try state.find(web).card.width < state.find(mixed).card.width)
    #expect(try state.find(web).card.width < 240)
    #expect(try state.find(long).card.width == 320)
    #expect(try state.find(mixed).icon == nil)
    for item in state.windows {
        #expect(item.card.x >= 0 && item.card.x + item.card.width <= state.width)
        #expect(item.card.width >= 128)
    }
    state.layout(width: 200, height: 750)
    for item in state.windows {
        #expect(item.card.width <= 168 && item.card.x + item.card.width <= 200)
    }
    state.layout(width: 390, height: 750)
    #expect(try state.find(long).card.width == 320)
    await state.stop()
}

@Test @MainActor func windowCardFontChangesKeepCenterAndNormalGeometryIndependent() async throws {
    let state = WindowState()
    state.layout(width: 600, height: 750)
    state.setAvailable(true)
    let id = try await presentFixture(state, "font", title: "网页与绘图", icon: .emoji("👩🏽‍🎨"))
    try state.move(id, x: 20, y: 90)
    let normal = try state.find(id).normal
    for command in [WindowCommand.maximize, .minimize] {
        let revision = try state.find(id).revision
        let task = Task { try await state.change(id, command: command) }
        try await windowEventually { (try? state.find(id).revision) != revision }
        try acknowledge(state, id)
        try await task.value
    }
    try state.move(id, x: 100, y: 200)
    let previous = try state.find(id)
    state.layout(width: 600, height: 750, titleSize: 24)
    let larger = try state.find(id)
    #expect(larger.card.width > previous.card.width)
    #expect(larger.card.x + larger.card.width / 2 == previous.card.x + previous.card.width / 2)
    #expect(larger.card.y == 200 && larger.normal == normal && larger.icon == .emoji("👩🏽‍🎨"))
    #expect(larger.mode == .minimized && larger.restoreMode == .maximized)
    #expect(state.frame(larger) == larger.card && larger.presentationConfirmed)
    state.layout(width: 600, height: 750, titleSize: .nan)
    #expect(state.cardTitleSize == 24)
    state.layout(width: 600, height: 750, titleSize: 15)
    #expect(try state.find(id).card == previous.card)
    await state.stop()
}

@Test @MainActor func windowIconsRejectInvalidPayloadsBeforeCreatingWindows() async throws {
    let state = WindowState()
    state.setAvailable(true)
    for icon in [
        WindowIcon.system(name: ""), .system(name: "mobileharness.invalid.symbol"),
        .emoji("word"), .emoji("A"), .emoji("🎨🎨"),
        .image(Data()), .image(Data("broken image".utf8)), .image(Data(count: 1024 * 1024 + 1)),
    ] {
        await #expect(throws: WindowError.invalidIcon) {
            try await state.present(content: .init(rawValue: "invalid"), title: "Invalid", icon: icon)
        }
        #expect(state.windows.isEmpty)
    }
    for emoji in ["🎨", "👩🏽‍🎨", "🇨🇳", "1️⃣"] {
        #expect(try WindowIcon.emoji(emoji).prepared() == .emoji(emoji))
    }
    await state.stop()
}

@Test @MainActor func windowCustomIconIsBoundedAndRetainedUntilWindowCloses() async throws {
    let context = try #require(
        CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
    let sourceImage = try #require(context.makeImage())
    let sourceData = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(sourceData, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, sourceImage, nil)
    try #require(CGImageDestinationFinalize(destination))
    let state = WindowState()
    state.setAvailable(true)
    // Opening before the first native layout must still receive correct card geometry later.
    let id = try await presentFixture(state, "custom", title: "Custom artwork", icon: .image(sourceData as Data))
    state.layout(width: 390, height: 750)
    let item = try state.find(id)
    guard case .image(let data) = item.icon else {
        Issue.record("Missing custom icon")
        return
    }
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.width == 96 && decoded.height == 48)
    #expect(item.card.width >= 128 && item.card.width <= 320 && item.card.height == 48)
    for command in [WindowCommand.minimize, .restore, .close] {
        let revision = try state.find(id).revision
        let task = Task { try await state.change(id, command: command) }
        try await windowEventually { (try? state.find(id).revision) != revision }
        if command != .close { #expect(try state.find(id).icon == item.icon) }
        try acknowledge(state, id)
        try await task.value
    }
    #expect(state.windows.isEmpty)
    await state.stop()
}

@Test @MainActor func windowPresentationMetadataDoesNotFocusRestoreOrMoveItsNormalFrame() async throws {
    let state = WindowState()
    state.layout(width: 390, height: 750)
    state.setAvailable(true)
    let first = try await presentFixture(state, "one")
    let second = try await presentFixture(state, "two")
    let frame = try state.find(first).normal
    state.setPresentation(first, title: "Software flowchart", subtitle: "Writing index.html")
    #expect(try state.find(first).normal == frame)
    #expect(state.focusedID == second)
    #expect(try state.find(first).title == "Software flowchart")
    #expect(try state.find(first).subtitle == "Writing index.html")
    state.setAvailable(false)
    state.setPresentation(first, subtitle: "Saved while scene is hidden")
    #expect(try state.find(first).subtitle == "Saved while scene is hidden")
    await state.stop()
}
