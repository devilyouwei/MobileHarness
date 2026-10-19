import Foundation
import Testing

@testable import PlatformKit

private enum CaptureReadinessFixtureError: Error, Equatable { case invalidPCM }

@Test(.actionCatalog) func audioCaptureReadinessRequiresPCMInsteadOfSessionStartup() async {
    let readiness = AudioCaptureReadiness()
    let waiter = Task { try await readiness.wait() }
    try? await Task.sleep(for: .milliseconds(20))
    readiness.resolve(.success(()))
    do { try await waiter.value } catch { Issue.record("Expected actual PCM readiness: \(error)") }
    await #expect(throws: AudioCaptureReadinessError.alreadyWaiting) { try await readiness.wait() }
}

@Test(.actionCatalog) func audioCaptureReadinessAcceptsAFrameArrivingBeforeTheWaiter() async throws {
    let readiness = AudioCaptureReadiness()
    readiness.resolve(.success(()))
    try await readiness.wait()
}

@Test(.actionCatalog) func audioCaptureReadinessPreservesInitialFormatFailure() async {
    let readiness = AudioCaptureReadiness()
    readiness.resolve(.failure(CaptureReadinessFixtureError.invalidPCM))
    readiness.resolve(.success(()))
    await #expect(throws: CaptureReadinessFixtureError.invalidPCM) { try await readiness.wait() }
}

@Test(.actionCatalog) func audioCaptureReadinessCancellationDoesNotWaitForAHardwareCallback() async {
    let readiness = AudioCaptureReadiness()
    let waiter = Task { try await readiness.wait() }
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    readiness.resolve(.success(()))
}

@Test(.actionCatalog) func audioCaptureReadinessAdmitsOnlyOneConcurrentWaiter() async {
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

@Test(.actionCatalog) func audioCaptureReadinessStopAndReplacementHaveIndependentResults() async throws {
    let oldCapture = AudioCaptureReadiness()
    oldCapture.resolve(.failure(CancellationError()))
    let replacement = AudioCaptureReadiness()
    replacement.resolve(.success(()))
    try await replacement.wait()
    await #expect(throws: CancellationError.self) { try await oldCapture.wait() }
}

@Test func continuousNativePCMRemainsValidAfterLongAbsoluteTimestamps() throws {
    var timeline = AudioPCMContinuity()
    let rate = 48000.0
    let origin = 100000.0
    for index in 0..<48000 {
        try timeline.accept(timestamp: origin + Double(index * 1024) / rate, frameCount: 1024, sampleRate: rate)
    }
}

@Test(arguments: [0.1, -0.1]) func nativeTimestampGapsAreDistinctFromQueueOverflow(_ gap: Double) throws {
    var timeline = AudioPCMContinuity()
    try timeline.accept(timestamp: 900, frameCount: 480, sampleRate: 48000)
    do {
        try timeline.accept(timestamp: 900.01 + gap, frameCount: 480, sampleRate: 48000)
        Issue.record("Discontinuous PCM must reject")
    } catch let error as AudioCaptureDiscontinuity {
        #expect(abs(error.gapSeconds - gap) < 0.000001)
        #expect(error.previousSampleRate == 48000 && error.actualSampleRate == 48000)
    }
    // A fresh physical capture owns an independent timeline after reply playback.
    timeline = AudioPCMContinuity()
    try timeline.accept(timestamp: 910, frameCount: 480, sampleRate: 48000)
}

@Test func nativeSampleRateChangeCarriesActualTimelineEvidence() throws {
    var timeline = AudioPCMContinuity()
    try timeline.accept(timestamp: 10, frameCount: 480, sampleRate: 48000)
    #expect(throws: AudioCaptureDiscontinuity.self) {
        try timeline.accept(timestamp: 10.01, frameCount: 441, sampleRate: 44100)
    }
}

@Test func invalidPCMDoesNotCommitNativeTimeline() throws {
    var timeline = AudioPCMContinuity()
    #expect(throws: AudioPCMContinuityError.self) {
        try timeline.accept(timestamp: .nan, frameCount: 480, sampleRate: 48000)
    }
    #expect(throws: AudioPCMContinuityError.self) {
        try timeline.accept(timestamp: 900, frameCount: 0, sampleRate: 48000)
    }
    try timeline.accept(timestamp: 1000, frameCount: 480, sampleRate: 48000)
}

@Test func audioRouteConfigurationKeepsSameDevicesButDetectsRealRouteLoss() {
    let builtIn = AudioRouteIdentity(inputs: ["mic:builtin"], outputs: ["speaker:builtin"])
    #expect(
        AudioSessionEventPolicy.routeChange(
            applicationChange: true, unavailable: false, previous: nil, current: builtIn) == nil)
    #expect(
        AudioSessionEventPolicy.routeChange(
            applicationChange: false, unavailable: false, previous: builtIn, current: builtIn) == nil)
    let reordered = AudioRouteIdentity(inputs: ["a", "b"], outputs: ["speaker:builtin"])
    #expect(
        AudioSessionEventPolicy.routeChange(
            applicationChange: false, unavailable: false,
            previous: .init(inputs: ["b", "a"], outputs: ["speaker:builtin"]), current: reordered) == nil)
    for changed in [
        AudioRouteIdentity(inputs: ["mic:headset"], outputs: ["speaker:builtin"]),
        AudioRouteIdentity(inputs: ["mic:builtin"], outputs: ["speaker:headset"]),
        AudioRouteIdentity(inputs: [], outputs: []),
    ] {
        #expect(
            AudioSessionEventPolicy.routeChange(
                applicationChange: false, unavailable: false, previous: builtIn, current: changed) == .routeChanged)
    }
    #expect(
        AudioSessionEventPolicy.routeChange(
            applicationChange: false, unavailable: false, previous: nil, current: builtIn) == .routeChanged)
    #expect(
        AudioSessionEventPolicy.routeChange(
            applicationChange: false, unavailable: true, previous: builtIn, current: builtIn) == .routeChanged)
}
