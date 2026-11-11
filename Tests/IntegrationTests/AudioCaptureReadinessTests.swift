import Foundation
import Testing

@testable import PlatformKit

#if os(iOS) || os(macOS)
    import AVFoundation
    import Synchronization

    @Test(arguments: [false, true])
    func spatialNativeFailurePreservesOriginalErrorBeforeAndAfterReadiness(ready: Bool) async throws {
        let center = NotificationCenter()
        let session = AVCaptureSession()
        let source = MicrophoneCapture()
        let readiness = AudioCaptureReadiness()
        let reports = Mutex<[PlatformFailure]>([])
        let admission = PlatformAdmission { _, _, error in
            if let failure = error as? PlatformFailure { reports.withLock { $0.append(failure) } }
        }
        let observer = SpatialAudioObservation(
            session: session, source: source, readiness: readiness, admission: admission, center: center)
        defer { observer.invalidate() }
        let input = try source.subscribe()
        if ready {
            readiness.resolve(.success(()))
            try await readiness.wait()
        }
        let original = NSError(
            domain: AVFoundationErrorDomain, code: -11819,  // iOS media-services reset captured in the device report.
            userInfo: [NSLocalizedDescriptionKey: "Media services reset", "diagnostic": "preserved"])
        center.post(
            name: AVCaptureSession.runtimeErrorNotification, object: session,
            userInfo: [AVCaptureSessionErrorKey: original])
        center.post(name: AVCaptureSession.wasInterruptedNotification, object: session)
        #expect(observer.failure as NSError? == original)
        #expect(!source.isActive)
        if !ready {
            do {
                try await readiness.wait()
                Issue.record("Startup must retain the native failure")
            } catch { #expect(error as NSError == original) }
        }
        do {
            for try await _ in input.frames {}
            Issue.record("PCM must terminate with the native failure")
        } catch { #expect(error as NSError == original) }
        let failures = reports.withLock { $0 }
        #expect(failures.count == 1)
        let failure = try #require(failures.first)
        #expect(failure.component == "audio.spatial" && failure.operation == "nativeEvent")
        #expect(failure.underlying as NSError == original)
        #expect((failure.underlying as NSError).userInfo["diagnostic"] as? String == "preserved")
    }

    @Test(arguments: [false, true])
    func spatialNativeMissingErrorAndInterruptionHaveDistinctFailures(interrupted: Bool) async throws {
        let center = NotificationCenter()
        let session = AVCaptureSession()
        let source = MicrophoneCapture()
        let readiness = AudioCaptureReadiness()
        let observer = SpatialAudioObservation(
            session: session, source: source, readiness: readiness, admission: nil, center: center)
        defer { observer.invalidate() }
        center.post(
            name: interrupted ? AVCaptureSession.wasInterruptedNotification : AVCaptureSession.runtimeErrorNotification,
            object: session)
        let expected: AudioIOError = interrupted ? .interrupted : .runtimeFailed
        await #expect(throws: expected) { try await readiness.wait() }
        let input = try source.subscribe()
        await #expect(throws: expected) { for try await _ in input.frames {} }
    }

    @Test func spatialNativeObserverIgnoresOtherSessionsAndNotificationsAfterStop() async throws {
        let center = NotificationCenter()
        let session = AVCaptureSession()
        let source = MicrophoneCapture()
        let readiness = AudioCaptureReadiness()
        let reports = Mutex(0)
        let observer = SpatialAudioObservation(
            session: session, source: source, readiness: readiness,
            admission: PlatformAdmission { _, _, _ in reports.withLock { $0 += 1 } }, center: center)
        center.post(name: AVCaptureSession.runtimeErrorNotification, object: AVCaptureSession())
        #expect(observer.failure == nil && source.isActive)
        observer.invalidate()
        readiness.resolve(.failure(CancellationError()))
        source.finish()
        center.post(name: AVCaptureSession.runtimeErrorNotification, object: session)
        center.post(name: AVCaptureSession.wasInterruptedNotification, object: session)
        #expect(observer.failure == nil)
        #expect(reports.withLock { $0 } == 0)
        await #expect(throws: CancellationError.self) { try await readiness.wait() }
        let input = try source.subscribe()
        for try await _ in input.frames { Issue.record("Stopped source has no frames") }
    }
#endif

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

@Test func echoCancellationUsesConfirmedSystemInputWithoutEnablingSecondProcessor() {
    var voiceAttempts = 0
    let selected = AudioEchoCancellationSelection.select(
        systemInput: { true },
        voiceProcessing: {
            voiceAttempts += 1
            return true
        },
        report: { _ in Issue.record("Unexpected failure") })
    #expect(selected == .systemInput && voiceAttempts == 0)
}

@Test(arguments: [false, true])
func echoCancellationFallsBackAfterUnsupportedOrFailedSystemInput(fails: Bool) {
    var reports: [AudioIOError] = []
    var voiceAttempts = 0
    let selected = AudioEchoCancellationSelection.select(
        systemInput: {
            if fails { throw AudioIOError.startFailed }
            return false
        },
        voiceProcessing: {
            voiceAttempts += 1
            return true
        },
        report: { if let error = $0 as? AudioIOError { reports.append(error) } })
    #expect(selected == .voiceProcessing && voiceAttempts == 1)
    #expect(reports == (fails ? [.startFailed] : []))
}

@Test func echoCancellationFailuresRemainVisibleAndNeverClaimDuplex() {
    var reports: [AudioIOError] = []
    let selected = AudioEchoCancellationSelection.select(
        systemInput: { throw AudioIOError.startFailed },
        voiceProcessing: { throw AudioIOError.runtimeFailed },
        report: { if let error = $0 as? AudioIOError { reports.append(error) } })
    #expect(selected == .unavailable)
    #expect(reports == [.startFailed, .runtimeFailed])
    let notEnabled = AudioEchoCancellationSelection.select(
        systemInput: { false }, voiceProcessing: { false }, report: { _ in Issue.record("Unexpected failure") })
    #expect(notEnabled == .unavailable)
}
