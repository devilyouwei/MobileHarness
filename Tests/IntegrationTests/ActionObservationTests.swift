import Actions
import AgentCore
import Agents
import AppWorkflows
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Testing
import UI

@testable import Gateway

private actor ObservationGate {
    private var entered = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        arrival?.resume()
        arrival = nil
        if released { return }
        await withCheckedContinuation { completion = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() {
        released = true
        completion?.resume()
        completion = nil
    }
}

private func observationCall(_ path: ActionPath, input: AgentInput, channel: String) -> ScheduledAction {
    ScheduledAction(source: .assistant, input: input, call: ActionCall(actionPath: path, channel: channel))
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func actionObservationTracksParallelChannelsAndQueuedWorkWithoutFeedbackOptIn()
    async throws
{
    let arm = ObservationGate()
    let speech = ObservationGate()
    let armPath = ActionPath(domain: "NexArm", module: "Gesture", function: "dance")
    let speechPath = ActionPath(domain: "Speech", module: "Playback", function: "speak")
    let registry = try ActionRegistry(definitions: [
        ActionBinding(path: armPath, displayName: "测试动作", kind: .finite, completion: "Fixture gate.") { _ in
            await arm.wait()
        },
        ActionBinding(path: speechPath, displayName: "测试动作", kind: .finite, completion: "Fixture gate.") { _ in
            await speech.wait()
        },
    ])
    let scheduler = ChannelScheduler(registry: registry)
    let stream = try await scheduler.observeExecutions()
    var iterator = stream.makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.records.isEmpty == true)
    let input = AgentInput(sessionID: UUID(), payload: .event("observation"))
    let armID = try await scheduler.enqueue(invocation: observationCall(armPath, input: input, channel: "Robot"))
    let speechID = try await scheduler.enqueue(invocation: observationCall(speechPath, input: input, channel: "Speech"))
    let queuedID = try await scheduler.enqueue(invocation: observationCall(armPath, input: input, channel: "Robot"))
    await arm.waitForEntry()
    await speech.waitForEntry()
    let snapshot = await scheduler.executionSnapshot()
    #expect(Set(snapshot.records.filter { $0.phase == .running }.map(\.id)) == [armID, speechID])
    #expect(snapshot.records.first { $0.id == queuedID }?.phase == .queued)
    await arm.release()
    await speech.release()
    try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    // Even if intermediate notifications coalesce, the full latest snapshot retains every terminal record.
    let latest = try #require(await iterator.next())
    #expect(latest.records.count == 3)
    #expect(latest.records.allSatisfy { $0.phase == .succeeded && $0.endedAt != nil })
    #expect(latest.revision > snapshot.revision)
    #expect(await scheduler.resultSnapshot().isEmpty)  // presentation is independent of Agent feedback
    await scheduler.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func actionObservationKeepsCancellingUntilCommittedHandlerJoins()
    async throws
{
    let gate = ObservationGate()
    let path = ActionPath(domain: "NexArm", module: "Gesture", function: "dance")
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(definitions: [
            ActionBinding(path: path, displayName: "测试动作", kind: .finite, completion: "Committed fixture is joined.") {
                _ in
                await gate.wait()
            }
        ]))
    let input = AgentInput(sessionID: UUID(), payload: .event("cancel"))
    let activeID = try await scheduler.enqueue(invocation: observationCall(path, input: input, channel: "Robot"))
    await gate.waitForEntry()
    let queuedID = try await scheduler.enqueue(invocation: observationCall(path, input: input, channel: "Robot"))
    let stream = try await scheduler.observeExecutions()
    let cancel = Task { await scheduler.cancel(inputID: input.id, source: AgentID(rawValue: "assistant")) }
    for await snapshot in stream {
        if snapshot.records.first(where: { $0.id == activeID })?.phase == .cancelling { break }
    }
    let pending = await scheduler.executionSnapshot()
    #expect(pending.records.first { $0.id == activeID }?.endedAt == nil)
    #expect(pending.records.first { $0.id == queuedID }?.phase == .cancelled)
    #expect(pending.records.first { $0.id == queuedID }?.startedAt == nil)
    await gate.release()
    await cancel.value
    let ended = await scheduler.executionSnapshot()
    #expect(ended.records.allSatisfy { $0.phase == .cancelled })
    #expect(ended.records.first { $0.id == activeID }?.startedAt != nil)
    await scheduler.shutdown()
}

@Test(.actionCatalog) func actionObservationRetainsActiveWorkBoundsHistoryAndIgnoresLateTransitions() {
    var ledger = ActionExecutionLedger(terminalCapacity: 2)
    let input = AgentInput(sessionID: UUID(), payload: .event("bounds"))
    let path = ActionPath(domain: "Fixture", module: "Control", function: "work")
    let active = observationCall(path, input: input, channel: "Robot")
    let definition = ActionBinding(
        path: path, displayName: "测试动作", kind: .finite, completion: "Fixture completed.", handler: { _ in })
    ledger.admit(active, definition: definition)
    ledger.transition(active.executionID, to: .running)
    var lastID = UUID()
    for _ in 0..<20 {
        let job = observationCall(path, input: input, channel: "Speech")
        ledger.admit(job, definition: definition)
        ledger.transition(job.executionID, to: .succeeded, completion: .completed)
        lastID = job.executionID
    }
    let snapshot = ledger.snapshot()
    #expect(snapshot.records.count == 3)
    #expect(snapshot.evictedCount == 18)
    #expect(snapshot.records.first?.id == active.executionID)
    let lateStart = ledger.transition(lastID, to: .running)
    #expect(!lateStart)
    let lateFailure = ledger.transition(lastID, to: .failed)
    #expect(!lateFailure)
    #expect(ledger.snapshot().revision == snapshot.revision)
}

@Test(.actionCatalog) func actionObservationPublishesStructuredFailureAndRejectsExcessSubscribers() async throws {
    let path = ActionPath(domain: "NexArm", module: "Gesture", function: "dance")
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(definitions: [
            ActionBinding(path: path, displayName: "测试动作", kind: .finite, completion: "Failure fixture.") {
                _ async throws -> Void in
                throw NexArmExecutionError.feedbackTimeout
            }
        ]))
    var streams: [AsyncStream<ActionExecutionSnapshot>] = []
    for _ in 0..<8 { streams.append(try await scheduler.observeExecutions()) }
    await #expect(throws: ChannelScheduler.ObservationError.self) { try await scheduler.observeExecutions() }
    let input = AgentInput(sessionID: UUID(), payload: .event("failure"))
    try await scheduler.enqueue(invocation: observationCall(path, input: input, channel: "Robot"))
    try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    let result = try #require(await scheduler.executionSnapshot().records.first)
    #expect(result.phase == .failed)
    #expect(result.failure?.rawValue == "feedbackTimeout")
    #expect(result.failureDescription == NexArmExecutionError.feedbackTimeout.localizedDescription)
    await scheduler.shutdown()
    var iterator = streams[0].makeAsyncIterator()
    let final = await iterator.next()
    let end = await iterator.next()
    #expect(final?.records.first?.phase == .failed)
    #expect(end == nil)
}

@Test(.actionCatalog) @MainActor func unfamiliarActionDisplaysItsRegisteredNameThroughTheWholeObservationPath()
    async throws
{
    // Explicit test-only behavior: no device, model or media access.
    let path = ActionPath(domain: "NewDomain", module: "Control", function: "newOperation")
    let registry = try ActionRegistry(definitions: [
        ActionBinding(path: path, displayName: "新领域操作", kind: .finite, completion: "Fixture acknowledged.") { _ in }
    ])
    let scheduler = ChannelScheduler(registry: registry)
    let state = ActionActivityState()
    let workflow = ActionActivityWorkflow(state: state)
    workflow.start { try await scheduler.observeExecutions() }
    let input = AgentInput(sessionID: UUID(), payload: .event("metadata fixture"))
    let id = try await scheduler.enqueue(invocation: observationCall(path, input: input, channel: "CustomLane"))
    try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    let snapshot = await scheduler.executionSnapshot()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while state.revision != snapshot.revision, ContinuousClock.now < deadline { await Task.yield() }
    let item = try #require(state.items.first { $0.id == id })
    #expect(item.title == "新领域操作")
    #expect(item.channelTitle == "CustomLane")
    #expect(item.status == "已完成")
    #expect(snapshot.records.first?.displayName == "新领域操作")
    #expect(await scheduler.resultSnapshot().isEmpty)
    await scheduler.shutdown()
}

@Test(.actionCatalog) func actionsOwnExecutionFailureMappingWithoutBluetoothDiagnostics() {
    let cases: [(NexArmExecutionError, String, String)] = [
        (.disconnected, "disconnected", "disconnected"),
        (.busy, "busy", "unavailable"),
        (.background, "background", "unavailable"),
        (.controlNotReady, "controlNotReady", "unavailable"),
        (.feedbackTimeout, "feedbackTimeout", "feedbackLost"),
        (.resourceBusy, "resourceUnavailable", "unavailable"),
        (.resourceUnavailable("Fixture"), "resourceUnavailable", "unavailable"),
    ]
    for (error, identifier, reportCode) in cases {
        #expect(error.actionExecutionFailure.rawValue == identifier)
        #expect(ActionReport.code(for: error).rawValue == reportCode)
    }
}

@Test(.actionCatalog) func composedFailurePreservesProducerMessageThroughSchedulerDelivery() async throws {
    enum FixtureFailure: LocalizedError {
        case failed
        var errorDescription: String? { "Fixture transport cause" }
    }
    let composition = try ActionComposition(
        .action("leaf", [], maximumResults: 2) {
            .report(
                try ActionReport(entries: [.init(path: "motor", status: .failed, code: .handlerFailed)])
                    .recordingFailure(FixtureFailure.failed))
        })
    let path = ActionPath(domain: "Fixture", module: "Control", function: "failure")
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(definitions: [
            ActionBinding(
                path: path, displayName: "Fixture", kind: .finite, completion: "Preserved error",
                completing: { _ in .report(try await composition.run()) })
        ]))
    let input = AgentInput(sessionID: UUID(), payload: .event("fixture"))
    _ = try await scheduler.enqueue(invocation: observationCall(path, input: input, channel: "Fixture"))
    try await scheduler.finish(inputID: input.id, source: .assistant)
    let record = try #require(await scheduler.executionSnapshot().records.first)
    #expect(record.phase == .failed)
    #expect(record.failureDescription == "Fixture transport cause")
    guard case .report(let report) = record.completion else {
        Issue.record("Expected preserved report")
        return
    }
    #expect(report.failureDescription == "Fixture transport cause")
    #expect(report.entries.count == 2)
    await scheduler.shutdown()
}

@Test(.actionCatalog, arguments: [false, true])
func cancelledActionPresentationRetainsOnlyIndependentRealIssues(_ mixed: Bool) throws {
    let report = try AgentActionReport(
        entries: [
            .init(
                path: "cancelled", status: .cancelled, code: .cancelled,
                details: ["failureDescription": "CancellationError()"])
        ] + (mixed ? [.init(path: "failed", status: .failed, code: .handlerFailed)] : [])
    )
    .withExecutionFailure(.cancelled, description: "CancellationError()")
    let record = ActionExecutionRecord(
        id: UUID(), path: .init(domain: "UI", module: "Caption", function: "print"),
        displayName: "Caption", source: .assistant, sessionID: UUID(), inputID: UUID(), channel: "Display",
        semantics: .finite, phase: mixed ? .failed : .cancelled, completion: .report(report))
    let item = ActionActivityItem(execution: record)
    #expect(item.isFailure == mixed)
    #expect(item.issueDescriptions.count == (mixed ? 1 : 0))
    #expect(!item.issueDescriptions.contains { $0.contains("CancellationError") })
}
