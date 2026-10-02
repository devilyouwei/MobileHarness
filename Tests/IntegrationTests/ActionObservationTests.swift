import ActionRuntime
import Actions
import AgentCore
import AppWorkflows
import Foundation
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

@Test(.timeLimit(.minutes(1))) func actionObservationTracksParallelChannelsAndQueuedWorkWithoutFeedbackOptIn()
    async throws
{
    let arm = ObservationGate()
    let speech = ObservationGate()
    let armPath = ActionPath(module: "NexArm", function: "dance")
    let speechPath = ActionPath(module: "Speech", function: "speak")
    let registry = try ActionRegistry(definitions: [
        ActionDefinition(path: armPath, displayName: "测试动作", kind: .finite, completion: "Fixture gate.") { _ in
            await arm.wait()
        },
        ActionDefinition(path: speechPath, displayName: "测试动作", kind: .finite, completion: "Fixture gate.") { _ in
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
    try await scheduler.finish(inputID: input.id)
    // Even if intermediate notifications coalesce, the full latest snapshot retains every terminal record.
    let latest = try #require(await iterator.next())
    #expect(latest.records.count == 3)
    #expect(latest.records.allSatisfy { $0.phase == .succeeded && $0.endedAt != nil })
    #expect(latest.revision > snapshot.revision)
    #expect(await scheduler.resultSnapshot().isEmpty)  // presentation is independent of Agent feedback
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func actionObservationKeepsCancellingUntilCommittedHandlerJoins() async throws {
    let gate = ObservationGate()
    let path = ActionPath(module: "NexArm", function: "dance")
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(definitions: [
            ActionDefinition(path: path, displayName: "测试动作", kind: .finite, completion: "Committed fixture is joined.")
            { _ in
                await gate.wait()
            }
        ]))
    let input = AgentInput(sessionID: UUID(), payload: .event("cancel"))
    let activeID = try await scheduler.enqueue(invocation: observationCall(path, input: input, channel: "Robot"))
    await gate.waitForEntry()
    let queuedID = try await scheduler.enqueue(invocation: observationCall(path, input: input, channel: "Robot"))
    let stream = try await scheduler.observeExecutions()
    let cancel = Task { await scheduler.cancel(inputID: input.id) }
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

@Test func actionObservationRetainsActiveWorkBoundsHistoryAndIgnoresLateTransitions() {
    var ledger = ActionExecutionLedger(terminalCapacity: 2)
    let input = AgentInput(sessionID: UUID(), payload: .event("bounds"))
    let path = ActionPath(module: "Fixture", function: "work")
    let active = observationCall(path, input: input, channel: "Robot")
    let definition = ActionDefinition(
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

@Test func actionObservationPublishesStructuredFailureAndRejectsExcessSubscribers() async throws {
    let path = ActionPath(module: "NexArm", function: "dance")
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(definitions: [
            ActionDefinition(path: path, displayName: "测试动作", kind: .finite, completion: "Failure fixture.") {
                _ async throws -> Void in
                throw BluetoothWorkflowError.feedbackTimeout
            }
        ]))
    var streams: [AsyncStream<ActionExecutionSnapshot>] = []
    for _ in 0..<8 { streams.append(try await scheduler.observeExecutions()) }
    await #expect(throws: ChannelScheduler.ObservationError.self) { try await scheduler.observeExecutions() }
    let input = AgentInput(sessionID: UUID(), payload: .event("failure"))
    try await scheduler.enqueue(invocation: observationCall(path, input: input, channel: "Robot"))
    try await scheduler.finish(inputID: input.id)
    let result = try #require(await scheduler.executionSnapshot().records.first)
    #expect(result.phase == .failed)
    #expect(result.failure == .feedbackTimeout)
    #expect(result.failureDescription == BluetoothWorkflowError.feedbackTimeout.localizedDescription)
    await scheduler.shutdown()
    var iterator = streams[0].makeAsyncIterator()
    let final = await iterator.next()
    let end = await iterator.next()
    #expect(final?.records.first?.phase == .failed)
    #expect(end == nil)
}

@Test @MainActor func unfamiliarActionDisplaysItsRegisteredNameThroughTheWholeObservationPath() async throws {
    // Explicit test-only behavior: no device, model or media access.
    let path = ActionPath(module: "NewDomain", function: "newOperation")
    let registry = try ActionRegistry(definitions: [
        ActionDefinition(path: path, displayName: "新领域操作", kind: .finite, completion: "Fixture acknowledged.") { _ in }
    ])
    let scheduler = ChannelScheduler(registry: registry)
    let state = ActionActivityState()
    let workflow = ActionActivityWorkflow(state: state)
    workflow.start { try await scheduler.observeExecutions() }
    let input = AgentInput(sessionID: UUID(), payload: .event("metadata fixture"))
    let id = try await scheduler.enqueue(invocation: observationCall(path, input: input, channel: "CustomLane"))
    try await scheduler.finish(inputID: input.id)
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
