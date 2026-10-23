import Actions
import Agents
import Foundation
import Gateway
import PlatformKit
import Testing

@testable import UI

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
    let workflow = AudioDetectionPresentation(state: state, endpoint: endpoint)
    let first = Task { try await workflow.run(readiness: AudioDetectionReadiness()) }
    try await detectionWait { state.phase == .running }
    let oldUpdate = try #require(endpoint.updates.first)
    var active = state.snapshot
    active.direction = .active
    active.azimuthDegrees = 45
    active.directionExpiresAt = .now.advanced(by: .milliseconds(500))
    oldUpdate(active)
    let stopping = Task { await workflow.stopAndWait() }
    try await detectionWait { endpoint.cleanup != nil }
    oldUpdate(active)
    #expect(state.phase == .stopping && state.snapshot.azimuthDegrees == nil)
    await #expect(throws: AudioDetectionError.busy) { try await workflow.run(readiness: AudioDetectionReadiness()) }
    endpoint.cleanup?.resume()
    endpoint.cleanup = nil
    await stopping.value
    _ = await first.result
    #expect(state.phase == .stopped)
    endpoint.holdCleanup = false
    let next = Task { try await workflow.run(readiness: AudioDetectionReadiness()) }
    try await detectionWait { endpoint.calls == 2 && state.phase == .running }
    oldUpdate(active)
    #expect(state.snapshot.azimuthDegrees == nil)
    await workflow.stopAndWait()
    _ = await next.result
}
@Test @MainActor func audioDetectionFinishesAutomaticallyAndClearsDirection() async throws {
    let state = AudioDetectionState()
    let endpoint = DetectionEndpoint()
    let workflow = AudioDetectionPresentation(state: state, endpoint: endpoint)
    let readiness = AudioDetectionReadiness()
    let operation = Task { try await workflow.run(readiness: readiness) }
    // The role's duration expires only after actual capture readiness.
    for await _ in readiness.events { break }
    readiness.cancel(completed: true)
    operation.cancel()
    _ = await operation.result
    #expect(state.phase == .finished && endpoint.cleanupStarted)
    #expect(state.snapshot.level == 0 && state.snapshot.azimuthDegrees == nil)
}
@Test @MainActor func audioDetectionKeepsFailedPermissionResultAndAllowsRetry() async throws {
    let state = AudioDetectionState()
    let endpoint = DetectionEndpoint()
    endpoint.failure = DetectionFixtureError.denied
    let workflow = AudioDetectionPresentation(state: state, endpoint: endpoint)
    await #expect(throws: (any Error).self) { try await workflow.run(readiness: AudioDetectionReadiness()) }
    #expect(state.snapshot.permissionGranted == false && state.phase == .failed)
    #expect(state.error?.contains("请允许麦克风访问") == true)
    endpoint.failure = nil
    let operation = Task { try await workflow.run(readiness: AudioDetectionReadiness()) }
    try await detectionWait { state.phase == .running }
    #expect(state.error == nil && state.snapshot.permissionGranted == true)
    await workflow.stopAndWait()
    _ = await operation.result
}
