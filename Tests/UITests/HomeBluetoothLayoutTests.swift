import CoreGraphics
import Foundation
import Testing

@testable import UI

@Test(arguments: [CGSize(width: 393, height: 59), CGSize(width: 402, height: 62), CGSize(width: 440, height: 62)])
func homeBluetoothHugsIslandWithSymmetricExpansion(viewport: CGSize) {
    let layout = HomeBluetoothLayout(viewportWidth: viewport.width, safeAreaTop: viewport.height)
    #expect(layout.attachesToIsland)
    let compact = layout.compactBackground.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)
    let glyph = CGPoint(x: layout.frame.minX + layout.glyphCenter.x, y: layout.frame.minY + layout.glyphCenter.y)
    #expect(glyph.y == compact.midY)
    #expect(compact.maxY == -12)
    #expect(compact.midX == viewport.width / 2)
    #expect(layout.frame.midX == viewport.width / 2)
    #expect(compact.minX - layout.frame.minX == layout.frame.maxX - compact.maxX)
    #expect(compact.minX - layout.frame.minX == 24)
    #expect(layout.frame.minY == compact.minY && layout.frame.maxY == compact.maxY)
    #expect(abs(glyph.x + HomeBluetoothLayout.glyphHalfWidth - compact.minX) < 0.001)
    #expect(glyph.x - HomeBluetoothLayout.glyphHalfWidth > layout.frame.minX)
    #expect(layout.glyphCenter.x + layout.taskGlyphCenter.x == layout.size.width)
    #expect(layout.glyphCenter.y == layout.taskGlyphCenter.y)
    let spectrum = layout.spectrumFrame.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)
    #expect(spectrum.minY == compact.maxY)
    #expect(spectrum.minX == layout.frame.minX + layout.size.height / 2)
    #expect(spectrum.maxX == layout.frame.maxX - layout.size.height / 2)
    #expect(spectrum.width == 137)
    let compactWidth = spectrum.width * layout.spectrumScale(expanded: false)
    #expect(abs(compactWidth - 89) < 0.001)
    #expect(layout.spectrumScale(expanded: true) == 1)
    #expect(abs(layout.frame.midX - compactWidth / 2 - (compact.minX + compact.height / 2)) < 0.001)
    #expect(layout.frame.minX > 80)  // Leaves the leading clock area clear.
}

@Test(arguments: [
    CGSize(width: 375, height: 44), CGSize(width: 390, height: 47), CGSize(width: 874, height: 0),
    CGSize(width: 1024, height: 24),
])
func homeBluetoothStaysInsideSafeAreaWithoutIsland(viewport: CGSize) {
    let layout = HomeBluetoothLayout(viewportWidth: viewport.width, safeAreaTop: viewport.height)
    #expect(!layout.attachesToIsland)
    #expect(layout.compactBackground.isEmpty)
    #expect(layout.frame.minX >= 0 && layout.frame.minY >= 0)
    #expect(layout.center == CGPoint(x: 24, y: 16))
}

@Test(arguments: [BluetoothConnectionStatus.disconnected, .connecting, .connected])
func homeIslandOnlyExpandsForLiveBluetoothOrUnfinishedTask(status: BluetoothConnectionStatus) {
    for active in [false, true] {
        for hasTask in [false, true] {
            let value = HomeIslandPresentation(bluetooth: status, hasTask: hasTask, active: active)
            #expect(value.expanded == (active && (hasTask || status != .disconnected)))
            #expect(value.bluetoothVisible == (active && status != .disconnected))
            #expect(value.taskVisible == (active && hasTask))
        }
    }
}

@Test func homeIslandDisconnectTurnsGrayThenRetractsWithinOneSecondWithoutRestartingDelay() {
    for status: BluetoothConnectionStatus in [.connecting, .connected] {
        let connected = HomeIslandPresentation(bluetooth: status, active: true)
        let disconnected = HomeIslandPresentation(active: true)
        #expect(!disconnected.expanded && !disconnected.bluetoothVisible)
        let delay = disconnected.transitionDelay(from: connected)
        #expect(delay > 0)
        #expect(delay + HomeIslandPresentation.transitionDuration <= 1)
        #expect(disconnected.transitionDelay(from: disconnected) == 0)
        let reconnected = HomeIslandPresentation(bluetooth: .connecting, active: true)
        #expect(reconnected.expanded && reconnected.bluetoothVisible)
        #expect(reconnected.transitionDelay(from: disconnected) == 0)
    }
}

@Test func homeIslandTaskKeepsBackgroundOpenWhileDisconnectedBluetoothRetracts() {
    let connected = HomeIslandPresentation(bluetooth: .connected, hasTask: true, active: true)
    let taskOnly = HomeIslandPresentation(hasTask: true, active: true)
    #expect(taskOnly.expanded && taskOnly.taskVisible && !taskOnly.bluetoothVisible)
    #expect(taskOnly.transitionDelay(from: connected) == HomeIslandPresentation.grayDuration)
    let idle = HomeIslandPresentation(active: true)
    #expect(!idle.expanded && !idle.taskVisible)
    #expect(idle.transitionDelay(from: taskOnly) == 0)
    #expect(HomeIslandPresentation().transitionDelay(from: connected) == 0)
}

@Test @MainActor func homeIslandTaskIndicatorIncludesBackgroundAndWaitingButExcludesTerminalHistory() {
    let state = ActionActivityState()
    #expect(!state.hasOngoingTask)
    var task = TaskLogItem(
        id: UUID().uuidString, parentID: nil, requester: "assistant", executor: "photographer", title: "任务",
        phase: .running)
    task.execution = "background"
    for phase: TaskLogItem.Phase in [
        .requested, .accepted, .running, .waitingUser, .cancelling, .succeeded, .failed, .cancelled,
    ] {
        task.phase = phase
        state.updateTask(task, event: .init(id: UUID().uuidString, time: .now, title: "状态", detail: ""))
        state.selectedSource = "unrelated"
        state.selectedFilter = .failed
        #expect(state.hasOngoingTask == !task.isTerminal)
    }
    state.currentTaskID = UUID().uuidString
    #expect(state.hasOngoingTask)
    state.currentTaskID = nil
    #expect(!state.hasOngoingTask)
}
