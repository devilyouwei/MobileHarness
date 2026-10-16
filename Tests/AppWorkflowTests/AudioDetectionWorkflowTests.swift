import ActionBindings
import Actions
import AgentBindings
import Foundation
import Gateway
import PlatformKit
import Testing
import UI

@MainActor private final class DetectionEndpoint: AudioDetectionRunning {
    var calls = 0
    var updates: [@MainActor @Sendable (AudioDetectionSnapshot) -> Void] = []
    var holdCleanup = false
    var cleanupStarted = false
    var cleanup: CheckedContinuation<Void, Never>?
    var failure: (any Error)?
    func run(update: @escaping @MainActor @Sendable (AudioDetectionSnapshot) -> Void) async throws {
        calls += 1
        updates.append(update)
        var snapshot = AudioDetectionSnapshot()
        snapshot.permissionGranted = failure == nil
        snapshot.capture = .mono
        snapshot.capturedAt = .now
        snapshot.signal = .receiving
        update(snapshot)
        if let failure { throw failure }
        do { try await Task.sleep(for: .seconds(60)) } catch {
            cleanupStarted = true
            if holdCleanup { await withCheckedContinuation { cleanup = $0 } }
            throw error
        }
    }
}
private enum DetectionFixtureError: LocalizedError {
    case denied, timeout
    var errorDescription: String? { "请允许麦克风访问。" }
}
@MainActor private func detectionWait(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw DetectionFixtureError.timeout
}

@Test @MainActor func audioDetectionJoinsCleanupBeforeRestartAndIgnoresLateSnapshots() async throws {
    let state = AudioDetectionState()
    let endpoint = DetectionEndpoint()
    endpoint.holdCleanup = true
    let workflow = AudioDetectionWorkflow(state: state, endpoint: endpoint)
    workflow.start()
    workflow.start()
    try await detectionWait { state.phase == .running }
    #expect(endpoint.calls == 1)
    let oldUpdate = try #require(endpoint.updates.first)
    var active = state.snapshot
    active.direction = .active
    active.azimuthDegrees = 45
    active.directionExpiresAt = .now.advanced(by: .milliseconds(500))
    oldUpdate(active)
    workflow.stop()
    #expect(state.snapshot.azimuthDegrees == nil)
    oldUpdate(active)
    #expect(state.phase == .stopping && state.snapshot.azimuthDegrees == nil)
    try await detectionWait { endpoint.cleanup != nil }
    workflow.start()
    #expect(endpoint.calls == 1)
    endpoint.cleanup?.resume()
    endpoint.cleanup = nil
    await workflow.stopAndWait()
    #expect(state.phase == .stopped)
    endpoint.holdCleanup = false
    workflow.start()
    try await detectionWait { endpoint.calls == 2 && state.phase == .running }
    oldUpdate(active)
    #expect(state.snapshot.azimuthDegrees == nil)
    await workflow.stopAndWait()
    #expect(state.phase == .stopped)
}

@Test @MainActor func audioDetectionFinishesAutomaticallyAndClearsDirection() async throws {
    let state = AudioDetectionState()
    let endpoint = DetectionEndpoint()
    let workflow = AudioDetectionWorkflow(state: state, endpoint: endpoint, duration: .milliseconds(120))
    workflow.start()
    try await detectionWait { state.phase == .finished }
    #expect(endpoint.cleanupStarted)
    #expect(state.snapshot.capture == .mono)
    #expect(state.snapshot.level == 0 && state.snapshot.azimuthDegrees == nil)
    #expect(!state.isActive)
}

@Test @MainActor func audioDetectionKeepsFailedPermissionResultAndAllowsRetry() async throws {
    let state = AudioDetectionState()
    let endpoint = DetectionEndpoint()
    endpoint.failure = DetectionFixtureError.denied
    let workflow = AudioDetectionWorkflow(state: state, endpoint: endpoint)
    workflow.start()
    try await detectionWait { state.phase == .failed }
    #expect(state.snapshot.permissionGranted == false)
    #expect(state.error?.contains("请允许麦克风访问") == true)
    endpoint.failure = nil
    workflow.start()
    try await detectionWait { state.phase == .running }
    #expect(state.error == nil && state.snapshot.permissionGranted == true)
    await workflow.stopAndWait()
}
