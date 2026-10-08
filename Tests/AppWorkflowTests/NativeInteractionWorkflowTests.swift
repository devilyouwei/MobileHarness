import Agents
import AppSettingsWorkflow
import Foundation
import Testing
import UI

@MainActor private final class HeldInteraction {
    var calls: [AppInteractionIntent] = []
    var cameraCalls: [PhotographerCameraIntent.Operation] = []
    var pending: CheckedContinuation<Void, any Error>?
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var hold = true
    func perform(_ intent: AppInteractionIntent) async throws {
        calls.append(intent)
        try await wait()
    }
    func performCamera(_ operation: PhotographerCameraIntent.Operation) async throws {
        cameraCalls.append(operation)
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
    let controls = BluetoothInteractionWorkflow(
        state: state, initialFence: UUID(),
        fenceStop: {
            fences += 1
            return UUID()
        }, perform: { try await host.perform($0) })
    var started = host.started.stream.makeAsyncIterator()
    controls.scan()
    await started.next()
    for value in [0.1, 0.5, 0.9] { controls.setMotorVelocity(id: 1, value: value) }
    controls.stopMotorControl()
    host.finish(throwing: CancellationError())
    await controls.waitUntilIdle()
    #expect(fences == 1)
    #expect(host.calls.map { $0.parameters["operation"] } == ["scan", "stopMotorControl"])
    #expect(state.error == nil)
    controls.setMotorVelocity(id: 1, value: 0.5)
    await controls.waitUntilIdle()
    #expect(host.calls.last?.parameters["value"] == "0.5")
    await controls.shutdown()
}
@Test @MainActor func cameraCommandRejectsOverlapAndRecoversAfterFailure() async throws {
    let host = HeldInteraction()
    let state = CameraState()
    state.isEnabled = false
    let controls = CameraInteractionWorkflow(state: state, perform: { try await host.performCamera($0) })
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
}
