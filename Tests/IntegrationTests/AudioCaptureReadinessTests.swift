import Foundation
import Testing

@testable import PlatformKit

private enum CaptureReadinessFixtureError: Error, Equatable { case invalidPCM }

@Test func audioCaptureReadinessRequiresPCMInsteadOfSessionStartup() async {
    let readiness = AudioCaptureReadiness()
    // Native startRunning/isRunning must not resolve this gate without a validated PCM callback.
    await #expect(throws: AudioCaptureReadinessError.timedOut) {
        try await readiness.wait(timeout: .milliseconds(10))
    }
    readiness.resolve(.success(()))  // A late callback cannot revive the timed-out attempt.
    await #expect(throws: AudioCaptureReadinessError.alreadyWaiting) { try await readiness.wait() }
}

@Test func audioCaptureReadinessAcceptsAFrameArrivingBeforeTheWaiter() async throws {
    let readiness = AudioCaptureReadiness()
    readiness.resolve(.success(()))
    try await readiness.wait()
}

@Test func audioCaptureReadinessPreservesInitialFormatFailure() async {
    let readiness = AudioCaptureReadiness()
    readiness.resolve(.failure(CaptureReadinessFixtureError.invalidPCM))
    readiness.resolve(.success(()))
    await #expect(throws: CaptureReadinessFixtureError.invalidPCM) { try await readiness.wait() }
}

@Test func audioCaptureReadinessCancellationDoesNotWaitForAHardwareCallback() async {
    let readiness = AudioCaptureReadiness()
    let waiter = Task { try await readiness.wait(timeout: .seconds(30)) }
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    readiness.resolve(.success(()))
}

@Test func audioCaptureReadinessAdmitsOnlyOneConcurrentWaiter() async {
    let readiness = AudioCaptureReadiness()
    func wait() async -> Bool {
        do {
            try await readiness.wait()
            return true
        } catch {
            #expect(error as? AudioCaptureReadinessError == .alreadyWaiting)
            return false
        }
    }
    async let first = wait()
    async let second = wait()
    readiness.resolve(.success(()))
    let results = await [first, second]
    #expect(results.filter { $0 }.count == 1)
}

@Test func audioCaptureReadinessStopAndReplacementHaveIndependentResults() async throws {
    let oldCapture = AudioCaptureReadiness()
    oldCapture.resolve(.failure(CancellationError()))
    let replacement = AudioCaptureReadiness()
    replacement.resolve(.success(()))
    try await replacement.wait()
    await #expect(throws: CancellationError.self) { try await oldCapture.wait() }
}
