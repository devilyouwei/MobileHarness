import ActionBindings
import Actions
import AgentBindings
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
