import Actions
import Agents
import Foundation
import Gateway
import PlatformKit
import StorageCore
import Testing

@testable import UI

@MainActor private final class HeldInteraction {
    var calls: [[String: String]] = []
    var cameraFacings: [CameraDirection?] = []
    var cameraMediaIDs: [String?] = []
    var cameraCalls: [CameraInput.Operation] = []
    var pending: CheckedContinuation<Void, any Error>?
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var hold = true
    func perform(_ intent: [String: String]) async throws {
        calls.append(intent)
        try await wait()
    }
    func performCamera(
        _ operation: CameraInput.Operation, facing: CameraDirection?,
        mediaID: String? = nil
    )
        async throws
    {
        cameraMediaIDs.append(mediaID)
        cameraCalls.append(operation)
        cameraFacings.append(facing)
        try await wait()
    }
    private func wait() async throws {
        if hold {
            hold = false
            try await withCheckedThrowingContinuation {
                pending = $0
                started.continuation.yield(())
            }
        }
    }
    func finish(throwing error: (any Error)? = nil) {
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
        pending = nil
    }
}
@Test @MainActor func manualMotorIntentCoalescesAndStopFencesOldRequests() async throws {
    let host = HeldInteraction()
    let state = BluetoothSettingsState()
    var fences = 0
    var pageVisibility: [Bool] = []
    var openedSettings = 0
    let controls = BluetoothInteractionWorkflow(
        state: state, initialFence: UUID().uuidString,
        fenceStop: {
            fences += 1
            return UUID().uuidString
        }, pageVisibility: { pageVisibility.append($0) }, openSettings: { openedSettings += 1 },
        perform: { try await host.perform($0) })
    var started = host.started.stream.makeAsyncIterator()
    controls.scan()
    await started.next()
    controls.openPage()
    controls.closePage()
    controls.openSystemSettings()
    #expect(pageVisibility == [true, false] && openedSettings == 1)
    #expect(host.calls.count == 1)
    for value in [0.1, 0.5, 0.9] { controls.setMotorVelocity(id: 1, value: value) }
    controls.stopMotorControl()
    host.finish(throwing: CancellationError())
    await controls.waitUntilIdle()
    #expect(fences == 2)
    #expect(host.calls.map { $0["operation"] } == ["scan"])
    #expect(state.error == nil)
    controls.setMotorVelocity(id: 1, value: 0.5)
    await controls.waitUntilIdle()
    #expect(host.calls.last?["value"] == "0.5")
    await controls.shutdown()
}
@Test @MainActor func deviceStopDoesNotWaitForOrdinaryRequestCompletion() async throws {
    let host = HeldInteraction()
    let controls = BluetoothInteractionWorkflow(
        state: BluetoothSettingsState(), initialFence: UUID().uuidString,
        fenceStop: { UUID().uuidString }, pageVisibility: { _ in }, openSettings: {},
        perform: { try await host.perform($0) })
    var started = host.started.stream.makeAsyncIterator()
    controls.scan()
    await started.next()
    controls.stopScan()
    for _ in 0..<1000 {
        if host.calls.count == 2 { break }
        await Task.yield()
    }
    #expect(host.pending != nil)
    #expect(host.calls.map { $0["operation"] } == ["scan", "stopScan"])
    host.finish()
    await controls.waitUntilIdle()
    await controls.shutdown()
}
@Test @MainActor func cameraCommandRejectsOverlapAndRecoversAfterFailure() async throws {
    let host = HeldInteraction()
    let ui = UIContainer()
    try ui.start()
    let state = ui.camera.state
    #expect(!state.isEnabled)
    let controls = CameraInteractionWorkflow(
        presentation: ui.camera,
        perform: { operation, facing, mediaID in
            try await host.performCamera(operation, facing: facing, mediaID: mediaID)
        })
    var started = host.started.stream.makeAsyncIterator()
    controls.toggle()
    await started.next()
    controls.switchCamera()
    #expect(host.cameraCalls.count == 1)
    #expect(state.controlMessage != nil)
    #expect(state.message == nil)
    #expect(state.controlBusy)
    host.finish(throwing: CancellationError())
    await controls.waitUntilIdle()
    #expect(!state.controlBusy)
    #expect(state.controlMessage == nil)
    controls.retry()
    await controls.waitUntilIdle()
    #expect(host.cameraCalls == [.open, .retry])
    state.isEnabled = true
    controls.switchCamera()
    await controls.waitUntilIdle()
    state.facing = .back
    controls.switchCamera()
    await controls.waitUntilIdle()
    #expect(host.cameraFacings == [nil, nil, .back, .front])
}

@Test @MainActor func photoUIControlsPreserveSelectedIDAndAllowRetryAfterFailure() async throws {
    let host = HeldInteraction()
    let ui = UIContainer()
    try ui.start()
    let state = ui.camera.state
    let controls = CameraInteractionWorkflow(
        presentation: ui.camera,
        perform: { operation, facing, id in try await host.performCamera(operation, facing: facing, mediaID: id) })
    let original = "media_1"
    let replacement = "media_2"
    var started = host.started.stream.makeAsyncIterator()
    controls.savePhoto(original)
    await started.next()
    controls.ignorePhoto(replacement)
    #expect(host.cameraCalls == [.savePhoto])
    #expect(host.cameraMediaIDs == [original])
    #expect(state.photoMessage != nil)
    #expect(state.message == nil)
    host.finish(throwing: CancellationError())
    await controls.waitUntilIdle()
    controls.ignorePhoto(replacement)
    await controls.waitUntilIdle()
    #expect(host.cameraCalls == [.savePhoto, .ignorePhoto])
    #expect(host.cameraMediaIDs == [original, replacement])
}

@Test @MainActor func committedPhotoSaveIsVisibleWhenLaterRequestCompletionFails() async throws {
    let ui = UIContainer()
    try ui.start()
    let state = ui.camera.state
    let id = "media_1"
    var calls = 0
    let controls = CameraInteractionWorkflow(
        presentation: ui.camera,
        perform: { _, _, selected in
            calls += 1
            state.savedMediaID = selected
            throw CancellationError()
        })
    controls.savePhoto(id)
    await controls.waitUntilIdle()
    #expect(calls == 1)
    #expect(state.savedMediaID == id)
    #expect(state.photoMessage?.hasPrefix("已保存到 App 相册") == true)
}

@Test @MainActor func cameraOverlapHintClearsOnCompletionWithoutReplacingDeviceFailure() async throws {
    let ui = UIContainer()
    try ui.start()
    let state = ui.camera.state
    let host = HeldInteraction()
    let controls = CameraInteractionWorkflow(
        presentation: ui.camera,
        perform: { operation, facing, id in try await host.performCamera(operation, facing: facing, mediaID: id) })
    var started = host.started.stream.makeAsyncIterator()
    controls.toggle()
    // Busy is visible synchronously, before the asynchronous dispatch starts.
    #expect(state.controlBusy)
    await started.next()
    state.present(.message("设备中断"))
    controls.retry()
    #expect(state.controlMessage != nil)
    #expect(state.message == "设备中断")
    #expect(host.cameraCalls == [.open])
    host.finish()
    await controls.waitUntilIdle()
    #expect(!state.controlBusy)
    #expect(state.controlMessage == nil)
    #expect(state.message == "设备中断")
    controls.retry()
    await controls.waitUntilIdle()
    #expect(host.cameraCalls == [.open, .retry])
    await ui.stop()
}
