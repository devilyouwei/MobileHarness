import Actions
import Agents
import Foundation
import Gateway
import PlatformKit
import Testing

private enum CaptureTransitionFailure: Error, Equatable { case unavailable }

@MainActor private final class MicrophoneTransitionProbe {
    var starts = 0
    var stops = 0
    var running = false
    var heldStart = false
    var failStart = false
    var trace: [String] = []
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(4))
    private var release: CheckedContinuation<Void, Never>?
    func start() async throws {
        starts += 1
        trace.append("start\(starts)")
        if heldStart, starts == 1 {
            await withCheckedContinuation {
                release = $0
                entered.continuation.yield(())
            }
            // Deliberately ignores cancellation: the owner must still retire this native graph.
        }
        running = true
        if failStart { throw CaptureTransitionFailure.unavailable }
        trace.append("ready\(starts)")
    }
    func stop() async {
        stops += 1
        running = false
        trace.append("stop\(stops)")
    }
    func finishStart() {
        release?.resume()
        release = nil
    }
    func workflow() -> ListeningCaptureWorkflow {
        ListeningCaptureWorkflow(start: { try await self.start() }, stop: { await self.stop() })
    }
}

@Test @MainActor func replyPauseStopsMicrophoneBeforePlaybackAndResumeUsesFreshCapture() async throws {
    let probe = MicrophoneTransitionProbe()
    let workflow = probe.workflow()
    try await workflow.setEnabled(true)
    try await workflow.setEnabled(true)
    #expect(probe.starts == 1 && probe.running)
    try await workflow.setEnabled(false)
    #expect(!probe.running && probe.stops == 1)
    probe.trace.append("playbackAndTail")
    try await workflow.setEnabled(true)
    #expect(probe.trace == ["start1", "ready1", "stop1", "playbackAndTail", "start2", "ready2"])
    await workflow.stop()
    #expect(!probe.running && probe.stops == 2)
}

@Test @MainActor func userOffJoinsPendingNativeStartEvenWhenNativeIgnoresCancellation() async throws {
    let probe = MicrophoneTransitionProbe()
    probe.heldStart = true
    let workflow = probe.workflow()
    let starting = Task { try await workflow.setEnabled(true) }
    var entered = probe.entered.stream.makeAsyncIterator()
    await entered.next()
    workflow.invalidate()
    let stopping = Task { await workflow.stop() }
    #expect(probe.stops == 0)
    probe.finishStart()
    await stopping.value
    await #expect(throws: CancellationError.self) { try await starting.value }
    #expect(probe.starts == 1 && probe.stops == 1 && !probe.running)
}

@Test @MainActor func newResumeJoinsRetiredStartupBeforeStartingReplacement() async throws {
    let probe = MicrophoneTransitionProbe()
    probe.heldStart = true
    let workflow = probe.workflow()
    let original = Task { try await workflow.setEnabled(true) }
    var entered = probe.entered.stream.makeAsyncIterator()
    await entered.next()
    workflow.invalidate()
    let replacement = Task { try await workflow.setEnabled(true) }
    await Task.yield()
    #expect(probe.starts == 1)
    probe.finishStart()
    await #expect(throws: CancellationError.self) { try await original.value }
    try await replacement.value
    #expect(probe.trace == ["start1", "ready1", "stop1", "start2", "ready2"])
    await workflow.stop()
}

@Test @MainActor func nativeStartFailureCleansUpAndExplicitRetryCanRecover() async throws {
    let probe = MicrophoneTransitionProbe()
    probe.failStart = true
    let workflow = probe.workflow()
    await #expect(throws: CaptureTransitionFailure.unavailable) { try await workflow.setEnabled(true) }
    #expect(!probe.running && probe.stops == 1)
    probe.failStart = false
    try await workflow.setEnabled(true)
    #expect(probe.running && probe.starts == 2)
    await workflow.stop()
}

@Test @MainActor func duplicateNativeRequestsJoinWithoutCancellingEachOther() async throws {
    let probe = MicrophoneTransitionProbe()
    probe.heldStart = true
    let workflow = probe.workflow()
    let first = Task { try await workflow.setEnabled(true) }
    var entered = probe.entered.stream.makeAsyncIterator()
    await entered.next()
    let second = Task { try await workflow.setEnabled(true) }
    await Task.yield()
    probe.finishStart()
    try await first.value
    try await second.value
    #expect(probe.starts == 1 && probe.running)
    async let policyPause: Void = workflow.setEnabled(false)
    async let playbackPause: Void = workflow.setEnabled(false)
    _ = try await (policyPause, playbackPause)
    #expect(probe.stops == 1 && !probe.running)
}

@Test @MainActor func captureRecoveryRetiresBeforeRestoreAndNeverRetriesTwice() async {
    var trace: [String] = []
    var failures: [String] = []
    let recovery = VoiceCaptureRecovery(
        retire: { trace.append("retired") }, restore: { trace.append("firstPCM") },
        report: { failures.append($0) })
    recovery.request("native reset")
    #expect(recovery.blocked)
    await recovery.wait()
    #expect(trace == ["retired", "firstPCM"] && !recovery.blocked)
    recovery.request("second fault")
    await recovery.wait()
    #expect(trace == ["retired", "firstPCM", "retired"] && recovery.blocked)
    #expect(failures.count == 1 && failures[0].contains("second fault"))
}

@Test @MainActor func captureRecoveryFailureKeepsUnavailableAndRetiresPartialStart() async {
    var retired = 0
    var started = 0
    var failures: [String] = []
    let recovery = VoiceCaptureRecovery(
        retire: { retired += 1 },
        restore: {
            started += 1
            throw CaptureTransitionFailure.unavailable
        }, report: { failures.append($0) })
    recovery.request("reset")
    await recovery.wait()
    #expect(recovery.blocked && retired == 2 && started == 1)
    #expect(failures.count == 1 && failures[0].contains("unavailable"))
    recovery.request("again")
    await recovery.wait()
    #expect(started == 1 && retired == 3)
}

@Test(.timeLimit(.minutes(1))) @MainActor func captureRecoveryUserOffJoinsRetirementAndCannotRestore() async {
    let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var release: CheckedContinuation<Void, Never>?
    var starts = 0
    var reports = 0
    let recovery = VoiceCaptureRecovery(
        retire: {
            await withCheckedContinuation {
                release = $0
                gate.continuation.yield(())
            }
        }, restore: { starts += 1 }, report: { _ in reports += 1 })
    recovery.request("reset")
    var entered = gate.stream.makeAsyncIterator()
    await entered.next()
    recovery.invalidate()
    recovery.request("late reset")
    release?.resume()
    await recovery.wait()
    #expect(recovery.blocked && starts == 0 && reports == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor func captureRecoveryTimeoutJoinsCancelledRestore() async {
    var retired = 0
    var restoreJoined = false
    var reports: [String] = []
    let recovery = VoiceCaptureRecovery(
        retire: { retired += 1 },
        restore: {
            defer { restoreJoined = true }
            try await Task.sleep(for: .seconds(30))
        }, report: { reports.append($0) }, timeout: .milliseconds(50))
    recovery.request("reset")
    await recovery.wait()
    #expect(recovery.blocked && restoreJoined && retired == 2)
    #expect(reports.count == 1 && reports[0].contains("timedOut"))
}

@Test @MainActor func captureInterruptionRetiresWithoutAutomaticRestart() async {
    var retired = 0
    var starts = 0
    let recovery = VoiceCaptureRecovery(
        retire: { retired += 1 }, restore: { starts += 1 }, report: { _ in })
    recovery.request("interrupted", restart: false)
    await recovery.wait()
    #expect(recovery.blocked && retired == 1 && starts == 0)
    recovery.request("later reset")
    await recovery.wait()
    #expect(recovery.blocked && retired == 2 && starts == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor func captureFaultDuringRestoreCannotBeClearedByLateSuccess() async {
    let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var release: CheckedContinuation<Void, Never>?
    var restores = 0
    var retired = 0
    let recovery = VoiceCaptureRecovery(
        retire: { retired += 1 },
        restore: {
            restores += 1
            await withCheckedContinuation {
                release = $0
                gate.continuation.yield(())
            }
        }, report: { _ in })
    recovery.request("reset")
    var entered = gate.stream.makeAsyncIterator()
    await entered.next()
    recovery.request("new capture failed")
    release?.resume()
    await recovery.wait()
    #expect(recovery.blocked && restores == 1 && retired == 2)
}

@Test(.timeLimit(.minutes(1))) @MainActor func captureRecoveryTimeoutCancelsOwnedNativeStartup() async {
    var nativeCancelled = false
    var nativeJoined = false
    var stops = 0
    let capture = ListeningCaptureWorkflow(
        start: {
            defer {
                nativeCancelled = Task.isCancelled
                nativeJoined = true
            }
            try await Task.sleep(for: .seconds(30))
        }, stop: { stops += 1 })
    let recovery = VoiceCaptureRecovery(
        retire: { await capture.stop() }, restore: {},
        resume: { try await capture.setEnabled(true) }, interruptRestore: { capture.invalidate() },
        report: { _ in }, timeout: .seconds(2))
    recovery.request("reset")
    await recovery.wait()
    #expect(nativeCancelled)
    #expect(nativeJoined)
    #expect(stops == 1)
    #expect(recovery.blocked)
}
