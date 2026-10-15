import Agents
import AppSettingsWorkflow
import Foundation
import Storage
import Testing
import UI

@MainActor private final class HeldInteraction {
    var calls: [AppInteractionIntent] = []
    var cameraFacings: [PhotographerCameraIntent.Facing?] = []
    var cameraMediaIDs: [String?] = []
    var cameraCalls: [PhotographerCameraIntent.Operation] = []
    var pending: CheckedContinuation<Void, any Error>?
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var hold = true
    func perform(_ intent: AppInteractionIntent) async throws {
        calls.append(intent)
        try await wait()
    }
    func performCamera(
        _ operation: PhotographerCameraIntent.Operation, facing: PhotographerCameraIntent.Facing?,
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
    #expect(host.calls.map { $0.parameters["operation"] } == ["scan"])
    #expect(state.error == nil)
    controls.setMotorVelocity(id: 1, value: 0.5)
    await controls.waitUntilIdle()
    #expect(host.calls.last?.parameters["value"] == "0.5")
    await controls.shutdown()
}
@Test @MainActor func cameraCommandRejectsOverlapAndRecoversAfterFailure() async throws {
    let host = HeldInteraction()
    let state = CameraState()
    #expect(!state.isEnabled)
    let controls = CameraInteractionWorkflow(
        state: state,
        perform: { operation, facing, mediaID in
            try await host.performCamera(operation, facing: facing, mediaID: mediaID)
        })
    var started = host.started.stream.makeAsyncIterator()
    controls.toggle()
    await started.next()
    controls.switchCamera()
    #expect(host.cameraCalls.count == 1)
    #expect(state.message != nil)
    host.finish(throwing: CancellationError())
    await controls.waitUntilIdle()
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
    let state = CameraState()
    let controls = CameraInteractionWorkflow(
        state: state,
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
    let state = CameraState()
    let id = "media_1"
    var calls = 0
    let controls = CameraInteractionWorkflow(
        state: state,
        perform: { _, _, selected in
            calls += 1
            state.savedMediaID = selected
            throw CancellationError()
        })
    controls.savePhoto(id)
    await controls.waitUntilIdle()
    #expect(calls == 1)
    #expect(state.savedMediaID == id)
    #expect(state.photoMessage?.hasPrefix("已保存到相册") == true)
}
