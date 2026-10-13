import Actions
import AppWorkflows
import ExecutionRuntime
import Foundation
import FunctionContracts
import Testing

enum WakeFixtureFailure: String, Error, Sendable { case haptic, prepare, cue, capture }
private actor WakeProbe: UIFeedbackCapability {
    let failure: WakeFixtureFailure?
    let holdCue: Bool
    let holdHaptic: Bool
    let holdPreparation: Bool
    let entered = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(3))
    var events: [String] = []
    var children: [(FunctionRequest, ActionExecutionContext)] = []
    init(
        failure: WakeFixtureFailure? = nil, holdCue: Bool = false, holdHaptic: Bool = false,
        holdPreparation: Bool = false
    ) {
        self.failure = failure
        self.holdCue = holdCue
        self.holdHaptic = holdHaptic
        self.holdPreparation = holdPreparation
    }
    func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws {
        children.append((invocation.call, invocation.context))
        events.append("haptic")
        if failure == .haptic { throw WakeFixtureFailure.haptic }
        if holdHaptic {
            entered.continuation.yield("haptic")
            try await Task.sleep(for: .seconds(60))
        }
    }
    func prepare() async throws {
        events.append("prepare")
        if failure == .prepare { throw WakeFixtureFailure.prepare }
        if holdPreparation {
            entered.continuation.yield("prepare")
            try await Task.sleep(for: .seconds(60))
        }
    }
    func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws {
        children.append((invocation.call, invocation.context))
        events.append("cue")
        if failure == .cue { throw WakeFixtureFailure.cue }
        if holdCue {
            entered.continuation.yield("cue")
            try await Task.sleep(for: .seconds(60))
        }
        events.append("drained")
    }
    func capture() throws {
        events.append("capture")
        if failure == .capture { throw WakeFixtureFailure.capture }
    }
}
private func wakeInput() -> FunctionInvocation {
    FunctionInvocation(
        call: .init(actionPath: .init(domain: "Speech", module: "Listening", function: "update")),
        context: .init(source: "speechPerception", sessionID: UUID(), inputID: UUID(), sequence: 4),
        results: ActionReportStore())
}
private func wakeConfiguration() throws -> SpeechActions.ListeningFeedback {
    try .init(cue: .init(cue: .soft, volume: 0.6), haptic: .init(style: .rigid, intensity: 0.9))
}

@Test func listeningCompositionUsesCanonicalChildrenAndDrainsBeforeCapture() async throws {
    let probe = WakeProbe()
    let input = wakeInput()
    try await ListeningActivationFeedback.run(
        invocation: input, configuration: wakeConfiguration(), feedback: probe,
        prepare: { try await probe.prepare() }, capture: { try await probe.capture() }, tail: .zero)
    let events = await probe.events
    #expect(events.last == "capture" && events.contains("prepare"))
    #expect(events.contains("haptic") && events.contains("drained"))
    let children = await probe.children
    #expect(Set(children.map { $0.0.actionPath.description }) == ["UI.Feedback.vibrate", "UI.Feedback.playCue"])
    #expect(children.allSatisfy { $0.1 == input.context })
    #expect(children.first { $0.0.actionPath.function == "vibrate" }?.0.parameters["style"] == "rigid")
    #expect(children.first { $0.0.actionPath.function == "playCue" }?.0.parameters["cue"] == "soft")
    let report = try #require(await input.results.snapshot())
    #expect(!report.hasFailures && !report.isCancelled)
    #expect(report.entries.contains { $0.path.contains("playCue") && $0.status == .succeeded })
    #expect(report.entries.last?.path == "capture.root.open")
}

@Test(arguments: [WakeFixtureFailure.haptic, .prepare, .cue, .capture])
func failedListeningPrerequisiteBlocksCaptureAndRetainsActualChildren(_ failure: WakeFixtureFailure) async throws {
    let probe = WakeProbe(failure: failure)
    let input = wakeInput()
    await #expect(throws: ListeningActivationFeedback.Failure.self) {
        try await ListeningActivationFeedback.run(
            invocation: input, configuration: wakeConfiguration(), feedback: probe,
            prepare: { try await probe.prepare() }, capture: { try await probe.capture() }, tail: .zero)
    }
    let events = await probe.events
    if failure != .capture { #expect(!events.contains("capture")) }
    #expect(events.contains("cue") && events.contains("haptic"))
    let report = try #require(await input.results.snapshot())
    #expect(report.hasFailures)
    #expect(report.entries.contains { $0.status == .failed })
    if failure == .cue { #expect(report.entries.contains { $0.path.contains("vibrate") && $0.status == .succeeded }) }
}

@Test(.timeLimit(.minutes(1))) func cancellationOfListeningCueJoinsAndNeverAdmitsCapture() async throws {
    let probe = WakeProbe(holdCue: true)
    let input = wakeInput()
    let task = Task {
        try await ListeningActivationFeedback.run(
            invocation: input, configuration: wakeConfiguration(), feedback: probe,
            prepare: { try await probe.prepare() }, capture: { try await probe.capture() }, tail: .zero)
    }
    var entered = probe.entered.stream.makeAsyncIterator()
    _ = await entered.next()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!(await probe.events).contains("capture"))
    #expect((await input.results.snapshot())?.isCancelled == true)
}

@Test(.timeLimit(.minutes(1))) func listeningReadinessCueAndHapticOverlapBeforeAnyChildCompletes() async throws {
    let probe = WakeProbe(holdCue: true, holdHaptic: true, holdPreparation: true)
    let input = wakeInput()
    let task = Task {
        try await ListeningActivationFeedback.run(
            invocation: input, configuration: wakeConfiguration(), feedback: probe,
            prepare: { try await probe.prepare() }, capture: { try await probe.capture() }, tail: .zero)
    }
    var entered = probe.entered.stream.makeAsyncIterator()
    let first = await entered.next()
    let second = await entered.next()
    let third = await entered.next()
    #expect(Set([first, second, third].compactMap { $0 }) == ["prepare", "haptic", "cue"])
    #expect(!(await probe.events).contains("drained"))
    #expect(!(await probe.events).contains("capture"))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect((await input.results.snapshot())?.isCancelled == true)
}

@Test @MainActor func listeningNativeStartGateReleasesFailsAndCancelsWithoutLeakingWaiters() async throws {
    let started = ListeningFeedbackStart()
    let waiter = Task { try await started.wait() }
    started.resolve(.success(()))
    try await waiter.value
    try await started.wait()

    let failed = ListeningFeedbackStart()
    let failureWaiter = Task { try await failed.wait() }
    failed.resolve(.failure(WakeFixtureFailure.cue))
    failed.resolve(.success(()))
    await #expect(throws: WakeFixtureFailure.self) { try await failureWaiter.value }

    let cancelled = ListeningFeedbackStart()
    let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let pending = Task {
        ready.continuation.yield(())
        try await cancelled.wait()
    }
    var entered = ready.stream.makeAsyncIterator()
    _ = await entered.next()
    pending.cancel()
    await #expect(throws: CancellationError.self) { try await pending.value }
}
