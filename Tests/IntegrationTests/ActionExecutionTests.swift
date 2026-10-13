import Actions
import AgentCore
import Agents
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import Testing

private actor ActionTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor ActionTestLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private let actionTestAgent = AgentID.assistant
private let sayPath = ActionPath(domain: "Speech", module: "Playback", function: "speak")
private let printPath = ActionPath(domain: "UI", module: "Caption", function: "print")

private func actionInvocation(
    _ text: String, input: AgentInput, source: AgentID = actionTestAgent, path: ActionPath = sayPath,
    channel: String? = nil
) -> ActionInvocation {
    let token = ActionCall(actionPath: path, channel: channel ?? path.domain, parameters: ["text": text])
    return ActionInvocation(source: source, input: input, call: token)
}

@Test(.actionCatalog) func actionsSerializeEachChannelAndAllowIndependentChannelsToProgress() async throws {
    let firstStarted = ActionTestGate()
    let releaseSpeech = ActionTestGate()
    let displayFinished = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { invocation in
                let text = invocation.call.parameters["text"] ?? ""
                await log.append("\(text):start")
                if text == "first" {
                    await firstStarted.open()
                    await releaseSpeech.wait()
                }
                await log.append("\(text):end")
            },
            printPath: { _ in
                await log.append("print")
                await displayFinished.open()
            },
        ]))
    let input = AgentInput(sessionID: UUID(), payload: .text("question"))
    try await executor.enqueue(invocation: actionInvocation("first", input: input))
    await firstStarted.wait()
    try await executor.enqueue(invocation: actionInvocation("second", input: input))
    try await executor.enqueue(invocation: actionInvocation("first", input: input, path: printPath))
    await displayFinished.wait()
    #expect(await log.values == ["first:start", "print"])
    let finishing = Task { try await executor.finish(inputID: input.id, source: AgentID(rawValue: "assistant")) }
    await releaseSpeech.open()
    try await finishing.value
    #expect(await log.values == ["first:start", "print", "first:end", "second:start", "second:end"])
}

@Test(.actionCatalog) func actionAdmissionBoundsIncludeRunningWorkAndRetainedInputs() async throws {
    let gate = ActionTestGate()
    let executor = ChannelScheduler(
        registry: try testActionRegistry(handlers: [sayPath: { _ in await gate.wait() }, printPath: { _ in }]),
        capacityPerChannel: 1, maximumTrackedInputs: 1)
    let first = AgentInput(sessionID: UUID(), payload: .text("first"))
    let second = AgentInput(sessionID: UUID(), payload: .text("second"))
    try await executor.enqueue(invocation: actionInvocation("one", input: first))
    await #expect(throws: ActionSchedulingError.channelCapacityExceeded("Speech")) {
        try await executor.enqueue(invocation: actionInvocation("two", input: first))
    }
    await #expect(throws: ActionSchedulingError.inputCapacityExceeded) {
        try await executor.enqueue(invocation: actionInvocation("two", input: second, path: printPath))
    }
    await gate.open()
    try await executor.finish(inputID: first.id, source: AgentID(rawValue: "assistant"))
    try await executor.enqueue(invocation: actionInvocation("two", input: second, path: printPath))
    try await executor.finish(inputID: second.id, source: AgentID(rawValue: "assistant"))
    await #expect(
        throws: ActionExecutionError.missingHandler(
            ActionIdentifier(domain: "Device", module: "Control", function: "move"))
    ) {
        try await executor.enqueue(
            invocation: actionInvocation(
                "three", input: second, path: ActionPath(domain: "Device", module: "Control", function: "move")))
    }
}

private enum ActionTestFailure: Error, Equatable { case playback }

@Test(.actionCatalog) func duplicateActionFinishWaiterIsRejectedAndOriginalWaiterCompletes() async throws {
    let gate = ActionTestGate()
    let executor = ChannelScheduler(registry: try testActionRegistry(handlers: [sayPath: { _ in await gate.wait() }]))
    let input = AgentInput(sessionID: UUID(), payload: .text("first"))
    try await executor.enqueue(invocation: actionInvocation("first", input: input))
    await withTaskGroup(of: String.self) { group in
        for _ in 0..<2 {
            group.addTask {
                do {
                    try await executor.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
                    return "completed"
                } catch ActionSchedulingError.duplicateFinish {
                    return "duplicate"
                } catch {
                    return "unexpected error: \(error)"
                }
            }
        }
        #expect(await group.next() == "duplicate")
        await gate.open()
        #expect(await group.next() == "completed")
    }
}

@Test(.actionCatalog) func actionFailureRecordsErrorAndRunsFollowingActions() async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { invocation in
                let text = invocation.call.parameters["text"] ?? ""
                await log.append(text)
                if text == "fail" {
                    await started.open()
                    await release.wait()
                    throw ActionTestFailure.playback
                }
            }
        ]))
    let failedInput = AgentInput(sessionID: UUID(), payload: .text("first"))
    let otherInput = AgentInput(sessionID: UUID(), payload: .text("second"))
    try await executor.enqueue(invocation: actionInvocation("fail", input: failedInput))
    await started.wait()
    try await executor.enqueue(invocation: actionInvocation("must not run", input: failedInput))
    try await executor.enqueue(invocation: actionInvocation("other input", input: otherInput))
    await release.open()
    try await executor.finish(inputID: failedInput.id, source: AgentID(rawValue: "assistant"))
    try await executor.finish(inputID: otherInput.id, source: AgentID(rawValue: "assistant"))
    let values = await log.values
    #expect(values.count == 3 && Set(values) == ["fail", "must not run", "other input"])
    #expect(values.first == "fail")
}

@Test(.actionCatalog) func cancellingFinishWaitsForHandlerCleanupAndSuppressesQueuedActions() async throws {
    let started = ActionTestGate()
    let sawCancellation = ActionTestGate()
    let releaseCleanup = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { invocation in
                let text = invocation.call.parameters["text"] ?? ""
                await log.append("\(text):start")
                if text == "old" {
                    await started.open()
                    await withTaskCancellationHandler {
                        await releaseCleanup.wait()
                    } onCancel: {
                        Task { await sawCancellation.open() }
                    }
                }
                await log.append("\(text):end")
            }
        ]), capacityPerChannel: 2)
    let old = AgentInput(sessionID: UUID(), payload: .text("old"))
    let next = AgentInput(sessionID: UUID(), payload: .text("new"))
    try await executor.enqueue(invocation: actionInvocation("old", input: old))
    await started.wait()
    try await executor.enqueue(invocation: actionInvocation("discard", input: old))
    let finishing = Task {
        do {
            try await executor.finish(inputID: old.id, source: AgentID(rawValue: "assistant"))
        } catch {
            await log.append("finish:returned")
            throw error
        }
        await log.append("finish:returned")
    }
    finishing.cancel()
    await sawCancellation.wait()
    let before = await log.values
    #expect(!before.contains("old:end") && !before.contains("finish:returned") && !before.contains("discard:start"))
    try await executor.enqueue(invocation: actionInvocation("new", input: next))
    // Independent inputs may run concurrently; cancellation joins only the old input.
    let afterAdmission = await log.values
    #expect(!afterAdmission.contains("old:end") && !afterAdmission.contains("finish:returned"))
    await releaseCleanup.open()
    await #expect(throws: CancellationError.self) { try await finishing.value }
    try await executor.finish(inputID: next.id, source: AgentID(rawValue: "assistant"))
    let values = await log.values
    #expect(Set(values) == ["old:start", "old:end", "new:start", "new:end", "finish:returned"])
    let oldEnd = try #require(values.firstIndex(of: "old:end"))
    let finish = try #require(values.firstIndex(of: "finish:returned"))
    #expect(oldEnd < finish)
    #expect(try #require(values.firstIndex(of: "new:start")) < #require(values.firstIndex(of: "new:end")))
}

@Test(.actionCatalog) func sessionCancellationCleansAllChannelLanesAndAllowsNextSession() async throws {
    let release = ActionTestGate()
    let speechStarted = ActionTestGate()
    let displayStarted = ActionTestGate()
    let speechCancelled = ActionTestGate()
    let displayCancelled = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { _ in
                await speechStarted.open()
                await withTaskCancellationHandler {
                    await release.wait()
                } onCancel: {
                    Task { await speechCancelled.open() }
                }
                try Task.checkCancellation()
                await log.append("speech")
            },
            printPath: { _ in
                await displayStarted.open()
                await withTaskCancellationHandler {
                    await release.wait()
                } onCancel: {
                    Task { await displayCancelled.open() }
                }
                try Task.checkCancellation()
                await log.append("display")
            },
        ]))
    let first = AgentInput(sessionID: UUID(), payload: .text("first"))
    let second = AgentInput(sessionID: first.sessionID, payload: .text("second"))
    try await executor.enqueue(invocation: actionInvocation("first", input: first))
    try await executor.enqueue(invocation: actionInvocation("second", input: second, path: printPath))
    await speechStarted.wait()
    await displayStarted.wait()
    let cancellation = Task { await executor.cancel(sessionID: first.sessionID) }
    // A second cancellation waits on the same completion tasks instead of registering unbounded waiters.
    let alsoCancel = Task { await executor.cancel(inputID: first.id, source: AgentID(rawValue: "assistant")) }
    await speechCancelled.wait()
    await displayCancelled.wait()
    await release.open()
    await cancellation.value
    await alsoCancel.value
    let next = AgentInput(sessionID: UUID(), payload: .text("next"))
    try await executor.enqueue(invocation: actionInvocation("next", input: next, path: printPath))
    try await executor.finish(inputID: next.id, source: AgentID(rawValue: "assistant"))
    #expect(await log.values == ["display"])
    await executor.shutdown()
    await #expect(throws: ActionSchedulingError.shutdown) {
        try await executor.enqueue(invocation: actionInvocation("stop", input: next))
    }
}

@Test(.actionCatalog) func sharedInputFinishDoesNotSealAnotherAgentsActions() async throws {
    let release = ActionTestGate()
    let started = ActionTestGate()
    let log = ActionTestLog()
    let secondAgent = AgentID(rawValue: "second")
    let executor = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            printPath: { _ in await log.append("first agent") },
            sayPath: { invocation in
                await started.open()
                await release.wait()
                await log.append(invocation.call.parameters["text"] ?? "")
            },
        ]))
    let shared = AgentInput(sessionID: UUID(), payload: .text("fan out"))
    try await executor.enqueue(invocation: actionInvocation("first", input: shared, path: printPath))
    try await executor.enqueue(invocation: actionInvocation("second:one", input: shared, source: secondAgent))
    await started.wait()
    // This must finish while the other agent's handler is still blocked.
    try await executor.finish(inputID: shared.id, source: AgentID(rawValue: "assistant"))
    try await executor.enqueue(invocation: actionInvocation("second:two", input: shared, source: secondAgent))
    await release.open()
    try await executor.finish(inputID: shared.id, source: secondAgent)
    #expect(await log.values == ["first agent", "second:one", "second:two"])
}

@Test(.actionCatalog) func sharedInputFailureDoesNotCancelEitherAgent() async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let log = ActionTestLog()
    let secondAgent = AgentID(rawValue: "second")
    let executor = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { invocation in
                let text = invocation.call.parameters["text"] ?? ""
                await log.append(text)
                if text == "fail" {
                    await started.open()
                    await release.wait()
                    throw ActionTestFailure.playback
                }
            }
        ]))
    let shared = AgentInput(sessionID: UUID(), payload: .text("fan out"))
    try await executor.enqueue(invocation: actionInvocation("fail", input: shared))
    await started.wait()
    try await executor.enqueue(invocation: actionInvocation("must not run", input: shared))
    try await executor.enqueue(invocation: actionInvocation("other agent", input: shared, source: secondAgent))
    await release.open()
    try await executor.finish(inputID: shared.id, source: AgentID(rawValue: "assistant"))
    try await executor.finish(inputID: shared.id, source: secondAgent)
    let values = await log.values
    #expect(values.count == 3 && Set(values) == ["fail", "must not run", "other agent"])
    #expect(values.first == "fail")
}

@Test(.actionCatalog) func explicitChannelSerializesDifferentModulesAndRestoresIndependentDefaults() async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let independent = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { _ in
                await log.append("say:start")
                await started.open()
                await release.wait()
                await log.append("say:end")
            },
            printPath: { invocation in
                let text = invocation.call.parameters["text"] ?? ""
                await log.append(text)
                if text == "default" { await independent.open() }
            },
        ]))
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    try await executor.enqueue(invocation: actionInvocation("hello", input: input, channel: "main"))
    await started.wait()
    try await executor.enqueue(
        invocation: actionInvocation("same-channel", input: input, path: printPath, channel: "main"))
    try await executor.enqueue(invocation: actionInvocation("default", input: input, path: printPath))
    await independent.wait()
    #expect(await log.values == ["say:start", "default"])
    await release.open()
    try await executor.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    #expect(await log.values == ["say:start", "default", "say:end", "same-channel"])
}

@Test(.actionCatalog) func channelCountBoundRejectsNewLaneWithoutDroppingExistingWork() async throws {
    let release = ActionTestGate()
    let executor = ChannelScheduler(
        registry: try testActionRegistry(handlers: [sayPath: { _ in await release.wait() }]), maximumChannels: 1)
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    try await executor.enqueue(invocation: actionInvocation("one", input: input, channel: "main"))
    await #expect(throws: ActionSchedulingError.channelCountExceeded) {
        try await executor.enqueue(invocation: actionInvocation("two", input: input, channel: "other"))
    }
    await release.open()
    try await executor.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    try await executor.enqueue(invocation: actionInvocation("three", input: input, channel: "other"))
    try await executor.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func sameFunctionRunsConcurrentlyAcrossDifferentChannels() async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let secondFinished = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { invocation in
                let text = invocation.call.parameters["text"] ?? ""
                await log.append("\(text):start")
                if text == "first" {
                    await started.open()
                    await release.wait()
                }
                await log.append("\(text):end")
                if text == "second" { await secondFinished.open() }
            }
        ]))
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    try await executor.enqueue(invocation: actionInvocation("first", input: input, channel: "main"))
    await started.wait()
    try await executor.enqueue(invocation: actionInvocation("second", input: input, channel: "Speech"))
    await secondFinished.wait()
    #expect(await log.values == ["first:start", "second:start", "second:end"])
    await release.open()
    try await executor.finish(inputID: input.id, source: .assistant)
    #expect(await log.values == ["first:start", "second:start", "second:end", "first:end"])
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func sameChannelInDifferentTasksRunsConcurrently() async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let secondFinished = ActionTestGate()
    let log = ActionTestLog()
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { invocation in
                let text = invocation.call.parameters["text"] ?? ""
                await log.append(text)
                if text == "first" {
                    await started.open()
                    await release.wait()
                } else {
                    await secondFinished.open()
                }
            }
        ]))
    let session = UUID()
    let first = AgentInput(sessionID: session, payload: .text("first"))
    let second = AgentInput(sessionID: session, payload: .text("second"))
    try await scheduler.enqueue(invocation: actionInvocation("first", input: first, channel: "shared"))
    await started.wait()
    try await scheduler.enqueue(invocation: actionInvocation("second", input: second, channel: "shared"))
    await secondFinished.wait()
    try await scheduler.finish(inputID: second.id, source: .assistant)
    #expect(await log.values == ["first", "second"])
    await release.open()
    try await scheduler.finish(inputID: first.id, source: .assistant)
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func resourceConflictFailsWithoutWaitingAndAdvancesItsChannel(sharedWriterGroup: Bool) async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let followingFinished = ActionTestGate()
    let log = ActionTestLog()
    let firstResource = ResourceID(rawValue: "fixture.first")
    let secondResource = sharedWriterGroup ? ResourceID(rawValue: "fixture.second") : firstResource
    let resourceIDs: Set<ResourceID> = [firstResource, secondResource]
    let coordinator = try ResourceCoordinator(
        definitions: resourceIDs.map {
            ResourceDefinition(
                id: $0, allowedOwners: [.assistant],
                executionGroup: sharedWriterGroup ? ResourceID(rawValue: "fixture.writer") : nil
            ) {}
        })
    let firstPath = ActionPath(domain: "Fixture", module: "Work", function: "first")
    let secondPath = ActionPath(domain: "Fixture", module: "Work", function: "second")
    let followingPath = ActionPath(domain: "Fixture", module: "Work", function: "following")
    let registry = try ActionRegistry(definitions: [
        ActionBinding(
            path: firstPath, displayName: "First", kind: .finite, completion: "Joined", resources: [firstResource]
        ) { _ async throws -> Void in
            await log.append("first:start")
            await started.open()
            await release.wait()
            await log.append("first:end")
        },
        ActionBinding(
            path: secondPath, displayName: "Second", kind: .finite, completion: "Joined", resources: [secondResource]
        ) { _ async throws -> Void in
            await log.append("conflicting handler must not run")
        },
        ActionBinding(path: followingPath, displayName: "Following", kind: .finite, completion: "Joined") {
            _ async throws -> Void in
            await log.append("following")
            await followingFinished.open()
        },
    ])
    let scheduler = ChannelScheduler(registry: registry, resources: coordinator)
    let input = AgentInput(sessionID: UUID(), payload: .event("resource conflict"))
    try await scheduler.enqueue(invocation: actionInvocation("first", input: input, path: firstPath, channel: "one"))
    await started.wait()
    try await scheduler.enqueue(invocation: actionInvocation("second", input: input, path: secondPath, channel: "two"))
    try await scheduler.enqueue(
        invocation: actionInvocation("following", input: input, path: followingPath, channel: "two"))
    await followingFinished.wait()
    #expect(await log.values == ["first:start", "following"])
    let snapshot = await scheduler.executionSnapshot()
    let failed = try #require(snapshot.records.first { $0.path == secondPath })
    #expect(failed.phase == .failed && failed.failure == .resourceUnavailable)
    #expect(failed.failureDescription?.contains("busy") == true)
    #expect(await coordinator.snapshot()[firstResource] != .unlocked)
    await release.open()
    try await scheduler.finish(inputID: input.id, source: .assistant)
    #expect(await log.values == ["first:start", "following", "first:end"])
    #expect(await coordinator.snapshot()[firstResource] == .unlocked)
}

private func boundary(_ directive: SchedulingDirective, _ input: AgentInput) -> OutputEnvelope {
    OutputEnvelope(source: .assistant, input: input, output: .scheduling(directive))
}

@Test(.actionCatalog) func waitGroupsJoinBeforeAndAfterWithoutBlockingIndependentTasks() async throws {
    let beforeStarted = ActionTestGate()
    let releaseBefore = ActionTestGate()
    let insideStarted = ActionTestGate()
    let releaseInside = ActionTestGate()
    let displayStarted = ActionTestGate()
    let releaseDisplay = ActionTestGate()
    let log = ActionTestLog()
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { invocation in
                let value = invocation.call.parameters["text"]!
                await log.append(value + ":start")
                if value == "before" {
                    await beforeStarted.open()
                    await releaseBefore.wait()
                }
                if value == "inside" {
                    await insideStarted.open()
                    await releaseInside.wait()
                }
                await log.append(value + ":end")
            },
            printPath: { invocation in
                let value = invocation.call.parameters["text"]!
                await log.append(value + ":start")
                if value == "display" {
                    await displayStarted.open()
                    await releaseDisplay.wait()
                }
                await log.append(value + ":end")
            },
        ]))
    let input = AgentInput(sessionID: UUID(), payload: .text("wait"))
    let other = AgentInput(sessionID: UUID(), payload: .text("independent"))
    try await scheduler.enqueue(invocation: actionInvocation("before", input: input))
    await beforeStarted.wait()
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.enqueue(invocation: actionInvocation("inside", input: input))
    try await scheduler.enqueue(invocation: actionInvocation("display", input: input, path: printPath))
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.enqueue(invocation: actionInvocation("after", input: input, path: printPath))
    // Dormant UI jobs do not obstruct another task using the same channel and module.
    try await scheduler.enqueue(invocation: actionInvocation("other", input: other, path: printPath))
    try await scheduler.finish(inputID: other.id, source: AgentID(rawValue: "assistant"))
    #expect(await log.values == ["before:start", "other:start", "other:end"])
    await releaseBefore.open()
    await insideStarted.wait()
    await displayStarted.wait()
    #expect(!(await log.values).contains("after:start"))
    await releaseInside.open()
    await releaseDisplay.open()
    try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    let values = await log.values
    #expect(values.firstIndex(of: "after:start")! > values.firstIndex(of: "inside:end")!)
    #expect(values.firstIndex(of: "after:start")! > values.firstIndex(of: "display:end")!)
}

@Test(.actionCatalog) func nestedWaitIsStreamingButUnclosedGroupCannotReleaseParentContinuation() async throws {
    let ran = ActionTestGate()
    let release = ActionTestGate()
    let log = ActionTestLog()
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { invocation in
                let value = invocation.call.parameters["text"]!
                await log.append(value)
                if value == "B" {
                    await ran.open()
                    await release.wait()
                }
            }
        ]))
    let input = AgentInput(sessionID: UUID(), payload: .text("nested"))
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.enqueue(invocation: actionInvocation("A", input: input))
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.enqueue(invocation: actionInvocation("B", input: input))
    await ran.wait()  // Executes even before the inner group has closed.
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.enqueue(invocation: actionInvocation("C", input: input))
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.enqueue(invocation: actionInvocation("D", input: input))
    #expect(await log.values == ["A", "B"])
    await release.open()
    try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    #expect(await log.values == ["A", "B", "C", "D"])
}

@Test(.actionCatalog) func malformedSchedulesAndGroupCapacityFailAndCleanup() async throws {
    let scheduler = ChannelScheduler(registry: try testActionRegistry(handlers: [:]))
    let input = AgentInput(sessionID: UUID(), payload: .text("limits"))
    await #expect(throws: ActionSchedulingError.invalidSchedule) {
        try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    }
    for _ in 0..<32 {
        try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
        try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    }
    await #expect(throws: ActionSchedulingError.waitGroupLimitExceeded) {
        try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    }
    try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    await #expect(throws: ActionSchedulingError.invalidSchedule) {
        try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    }
    for _ in 0..<8 { try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input)) }
    await #expect(throws: ActionSchedulingError.waitGroupLimitExceeded) {
        try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    }
    await scheduler.cancel(inputID: input.id, source: AgentID(rawValue: "assistant"))
}

@Test(.actionCatalog) func waitFailureReleasesDormantGroupsAndAllowsLateAdmission() async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let log = ActionTestLog()
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { invocation in
                if invocation.call.parameters["text"] == "probe" { return }
                await started.open()
                await release.wait()
                throw ActionTestFailure.playback
            },
            printPath: { _ in await log.append("unexpected") },
        ]))
    let input = AgentInput(sessionID: UUID(), payload: .text("failure"))
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.enqueue(invocation: actionInvocation("fail", input: input))
    await started.wait()
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.enqueue(invocation: actionInvocation("dormant", input: input, path: printPath))
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    await release.open()
    // An independent task can finish; late same-task work still follows the wait tree.
    let probe = AgentInput(sessionID: UUID(), payload: .text("probe"))
    try await scheduler.enqueue(invocation: actionInvocation("probe", input: probe))
    try await scheduler.finish(inputID: probe.id, source: AgentID(rawValue: "assistant"))
    try await scheduler.enqueue(invocation: actionInvocation("late", input: input, path: printPath))
    try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    #expect(await log.values == ["unexpected", "unexpected"])
}

@Test(.actionCatalog) func nestedWaitCancellationJoinsRunningCleanupAndDropsFuturePhases() async throws {
    let started = ActionTestGate()
    let cancelling = ActionTestGate()
    let release = ActionTestGate()
    let log = ActionTestLog()
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { _ in
                await started.open()
                await withTaskCancellationHandler {
                    await release.wait()
                } onCancel: {
                    Task { await cancelling.open() }
                }
                await log.append("cleaned")
            },
            printPath: { invocation in await log.append(invocation.call.parameters["text"]!) },
        ]))
    let input = AgentInput(sessionID: UUID(), payload: .text("cancel"))
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.enqueue(invocation: actionInvocation("active", input: input))
    await started.wait()
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.enqueue(invocation: actionInvocation("must not run", input: input, path: printPath))
    let cancellation = Task {
        await scheduler.cancel(inputID: input.id, source: AgentID(rawValue: "assistant"))
        await log.append("cancel returned")
    }
    await cancelling.wait()
    #expect(await log.values.isEmpty)
    let other = AgentInput(sessionID: UUID(), payload: .text("other"))
    try await scheduler.enqueue(invocation: actionInvocation("other", input: other, path: printPath))
    try await scheduler.finish(inputID: other.id, source: AgentID(rawValue: "assistant"))
    #expect(await log.values == ["other"])
    await release.open()
    await cancellation.value
    #expect(await log.values == ["other", "cleaned", "cancel returned"])
}

@Test(.actionCatalog) func dormantActionsCountTowardGlobalChannelAndTaskBounds() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("bounds"))
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [sayPath: { _ in }]), capacityPerChannel: 128)
    for _ in 0..<120 {
        try await scheduler.enqueue(invocation: actionInvocation("text", input: input))
    }
    await #expect(throws: ActionSchedulingError.taskActionLimitExceeded) {
        try await scheduler.enqueue(invocation: actionInvocation("excess", input: input))
    }
    try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))

    let release = ActionTestGate()
    let bounded = ChannelScheduler(
        registry: try testActionRegistry(handlers: [sayPath: { _ in await release.wait() }, printPath: { _ in }]),
        capacityPerChannel: 1)
    try await bounded.enqueue(invocation: actionInvocation("before", input: input))
    try await bounded.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await bounded.enqueue(invocation: actionInvocation("dormant", input: input, path: printPath))
    let other = AgentInput(sessionID: UUID(), payload: .text("other"))
    await #expect(throws: ActionSchedulingError.channelCapacityExceeded("UI")) {
        try await bounded.enqueue(invocation: actionInvocation("overflow", input: other, path: printPath))
    }
    await release.open()
    await bounded.cancel(inputID: input.id, source: AgentID(rawValue: "assistant"))
}

@Test(.actionCatalog) func schedulingCompletionRequiresTheActualCustomAgentSource() async throws {
    let log = ActionTestLog()
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [printPath: { _ in await log.append("custom") }]))
    let source = AgentID(rawValue: "customAgent")
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    try await scheduler.enqueue(invocation: actionInvocation("test", input: input, source: source, path: printPath))
    try await scheduler.finish(inputID: input.id, source: source)
    #expect(await log.values == ["custom"])
    await scheduler.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func parentAndChildSpeechRunIndependentlyWithoutCancellingParent()
    async throws
{
    let started = ActionTestGate()
    let release = ActionTestGate()
    let childFinished = ActionTestGate()
    let log = ActionTestLog()
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            sayPath: { invocation in
                await log.append("\(invocation.context.source):start")
                if invocation.context.source == "assistant" {
                    await started.open()
                    await release.wait()
                    try Task.checkCancellation()
                }
                await log.append("\(invocation.context.source):end")
                if invocation.context.source == "photographer" { await childFinished.open() }
            }
        ]))
    let session = UUID()
    let parent = AgentInput(sessionID: session, payload: .text("parent"))
    let child = AgentInput(sessionID: session, payload: .text("child"))
    try await scheduler.enqueue(invocation: actionInvocation("parent", input: parent, source: .assistant))
    await started.wait()
    try await scheduler.enqueue(invocation: actionInvocation("child", input: child, source: .photographer))
    await childFinished.wait()
    #expect(await log.values == ["assistant:start", "photographer:start", "photographer:end"])
    let parentFinish = Task { try await scheduler.finish(inputID: parent.id, source: .assistant) }
    let childFinish = Task { try await scheduler.finish(inputID: child.id, source: .photographer) }
    await release.open()
    try await parentFinish.value
    try await childFinish.value
    #expect(await log.values == ["assistant:start", "photographer:start", "photographer:end", "assistant:end"])
    await scheduler.shutdown()
}
