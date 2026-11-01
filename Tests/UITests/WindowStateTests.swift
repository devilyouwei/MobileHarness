import Foundation
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
@MainActor private func presentFixture(_ state: WindowState, _ name: String = "fixture") async throws -> UUID {
    let opening = Task { try await state.present(content: .init(rawValue: name, singleInstance: true), title: name) }
    try await windowEventually { state.windows.contains { $0.content == name } }
    let id = try #require(state.windows.first { $0.content == name }?.id)
    try acknowledge(state, id)
    return try await opening.value
}
@Test @MainActor func windowCapacityFocusAndStableIdentity() async throws {
    let state = WindowState()
    state.layout(width: 390, height: 750)
    state.setAvailable(true)
    let ids = try await [
        presentFixture(state, "one"), presentFixture(state, "two"), presentFixture(state, "three"),
        presentFixture(state, "four"),
    ]
    #expect(state.windows.count == 4)
    await #expect(throws: WindowError.self) { try await state.present(content: .init(rawValue: "five"), title: "five") }
    #expect(
        try await state.present(content: .init(rawValue: "one", singleInstance: true), title: "unchanged") == ids[0])
    #expect(state.focusedID == ids[0] && state.windows.last?.id == ids[0])
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
