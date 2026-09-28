import ActionRuntime
import Actions
import AgentCore
import Foundation
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
private let sayPath = ActionPath(module: "Speech", function: "speak")
private let printPath = ActionPath(module: "UI", function: "print")

private func actionInvocation(
    _ text: String, input: AgentInput, source: AgentID = actionTestAgent, path: ActionPath = sayPath,
    channel: String? = nil
) -> ActionInvocation {
    let token = ActionCall(actionPath: path, channel: channel ?? path.module, parameters: ["text": text])
    return ActionInvocation(
        envelope: OutputEnvelope(source: source, input: input, output: .actionCall(token)),
        call: token)
}

@Test func actionsSerializeEachModuleAndAllowIndependentModulesToProgress() async throws {
    let firstStarted = ActionTestGate()
    let releaseSpeech = ActionTestGate()
    let displayFinished = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: ActionRegistry(handlers: [
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
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("first", input: input))
    await firstStarted.wait()
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("second", input: input))
    try await executor.enqueue(path: printPath, invocation: actionInvocation("first", input: input, path: printPath))
    await displayFinished.wait()
    #expect(await log.values == ["first:start", "print"])
    let finishing = Task { try await executor.finish(inputID: input.id) }
    await releaseSpeech.open()
    try await finishing.value
    #expect(await log.values == ["first:start", "print", "first:end", "second:start", "second:end"])
}

@Test func actionAdmissionBoundsIncludeRunningWorkAndRetainedInputs() async throws {
    let gate = ActionTestGate()
    let executor = ChannelScheduler(
        registry: ActionRegistry(handlers: [sayPath: { _ in await gate.wait() }, printPath: { _ in }]),
        capacityPerChannel: 1, maximumTrackedInputs: 1)
    let first = AgentInput(sessionID: UUID(), payload: .text("first"))
    let second = AgentInput(sessionID: UUID(), payload: .text("second"))
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("one", input: first))
    await #expect(throws: ActionExecutionError.channelCapacityExceeded("Speech")) {
        try await executor.enqueue(path: sayPath, invocation: actionInvocation("two", input: first))
    }
    await #expect(throws: ActionExecutionError.inputCapacityExceeded) {
        try await executor.enqueue(path: printPath, invocation: actionInvocation("two", input: second, path: printPath))
    }
    await gate.open()
    try await executor.finish(inputID: first.id)
    try await executor.enqueue(path: printPath, invocation: actionInvocation("two", input: second, path: printPath))
    try await executor.finish(inputID: second.id)
    await #expect(throws: ActionExecutionError.missingHandler(ActionPath(module: "Device", function: "move"))) {
        try await executor.enqueue(
            path: ActionPath(module: "Device", function: "move"),
            invocation: actionInvocation("three", input: second))
    }
}

private enum ActionTestFailure: Error, Equatable { case playback }

@Test func duplicateActionFinishWaiterIsRejectedAndOriginalWaiterCompletes() async throws {
    let gate = ActionTestGate()
    let executor = ChannelScheduler(registry: ActionRegistry(handlers: [sayPath: { _ in await gate.wait() }]))
    let input = AgentInput(sessionID: UUID(), payload: .text("first"))
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("first", input: input))
    await withTaskGroup(of: String.self) { group in
        for _ in 0..<2 {
            group.addTask {
                do {
                    try await executor.finish(inputID: input.id)
                    return "completed"
                } catch ActionExecutionError.duplicateFinish {
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

@Test func actionFailureKeepsOriginalErrorAndRemovesQueuedActionsForThatInput() async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: ActionRegistry(handlers: [
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
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("fail", input: failedInput))
    await started.wait()
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("must not run", input: failedInput))
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("other input", input: otherInput))
    await release.open()
    await #expect(throws: ActionTestFailure.playback) { try await executor.finish(inputID: failedInput.id) }
    try await executor.finish(inputID: otherInput.id)
    #expect(await log.values == ["fail", "other input"])
}

@Test func cancellingFinishWaitsForHandlerCleanupAndSuppressesQueuedActions() async throws {
    let started = ActionTestGate()
    let sawCancellation = ActionTestGate()
    let releaseCleanup = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: ActionRegistry(handlers: [
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
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("old", input: old))
    await started.wait()
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("discard", input: old))
    let finishing = Task { try await executor.finish(inputID: old.id) }
    finishing.cancel()
    await sawCancellation.wait()
    #expect(await log.values == ["old:start"])
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("new", input: next))
    #expect(await log.values == ["old:start"])
    await releaseCleanup.open()
    await #expect(throws: CancellationError.self) { try await finishing.value }
    try await executor.finish(inputID: next.id)
    #expect(await log.values == ["old:start", "old:end", "new:start", "new:end"])
}

@Test func sessionCancellationCleansAllModuleLanesAndAllowsNextSession() async throws {
    let release = ActionTestGate()
    let speechStarted = ActionTestGate()
    let displayStarted = ActionTestGate()
    let speechCancelled = ActionTestGate()
    let displayCancelled = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: ActionRegistry(handlers: [
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
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("first", input: first))
    try await executor.enqueue(path: printPath, invocation: actionInvocation("second", input: second, path: printPath))
    await speechStarted.wait()
    await displayStarted.wait()
    let cancellation = Task { await executor.cancel(sessionID: first.sessionID) }
    // A second cancellation waits on the same completion tasks instead of registering unbounded waiters.
    let alsoCancel = Task { await executor.cancel(inputID: first.id) }
    await speechCancelled.wait()
    await displayCancelled.wait()
    await release.open()
    await cancellation.value
    await alsoCancel.value
    let next = AgentInput(sessionID: UUID(), payload: .text("next"))
    try await executor.enqueue(path: printPath, invocation: actionInvocation("next", input: next, path: printPath))
    try await executor.finish(inputID: next.id)
    #expect(await log.values == ["display"])
    await executor.shutdown()
    await #expect(throws: ActionExecutionError.shutdown) {
        try await executor.enqueue(path: sayPath, invocation: actionInvocation("stop", input: next))
    }
}

@Test func sharedInputFinishDoesNotSealAnotherAgentsActions() async throws {
    let release = ActionTestGate()
    let started = ActionTestGate()
    let log = ActionTestLog()
    let secondAgent = AgentID(rawValue: "second")
    let executor = ChannelScheduler(
        registry: ActionRegistry(handlers: [
            printPath: { _ in await log.append("first agent") },
            sayPath: { invocation in
                await started.open()
                await release.wait()
                await log.append(invocation.call.parameters["text"] ?? "")
            },
        ]))
    let shared = AgentInput(sessionID: UUID(), payload: .text("fan out"))
    try await executor.enqueue(path: printPath, invocation: actionInvocation("first", input: shared, path: printPath))
    try await executor.enqueue(
        path: sayPath, invocation: actionInvocation("second:one", input: shared, source: secondAgent))
    await started.wait()
    // This must finish while the other agent's handler is still blocked.
    try await executor.finish(inputID: shared.id)
    try await executor.enqueue(
        path: sayPath, invocation: actionInvocation("second:two", input: shared, source: secondAgent))
    await release.open()
    try await executor.finish(inputID: shared.id, source: secondAgent)
    #expect(await log.values == ["first agent", "second:one", "second:two"])
}

@Test func sharedInputFailureOnlyCancelsTheFailingAgentsActions() async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let log = ActionTestLog()
    let secondAgent = AgentID(rawValue: "second")
    let executor = ChannelScheduler(
        registry: ActionRegistry(handlers: [
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
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("fail", input: shared))
    await started.wait()
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("must not run", input: shared))
    try await executor.enqueue(
        path: sayPath, invocation: actionInvocation("other agent", input: shared, source: secondAgent))
    await release.open()
    await #expect(throws: ActionTestFailure.playback) { try await executor.finish(inputID: shared.id) }
    try await executor.finish(inputID: shared.id, source: secondAgent)
    #expect(await log.values == ["fail", "other agent"])
}

@Test func explicitChannelSerializesDifferentModulesAndRestoresIndependentDefaults() async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let independent = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: ActionRegistry(handlers: [
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
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("hello", input: input, channel: "main"))
    await started.wait()
    try await executor.enqueue(
        path: printPath, invocation: actionInvocation("same-channel", input: input, path: printPath, channel: "main"))
    try await executor.enqueue(path: printPath, invocation: actionInvocation("default", input: input, path: printPath))
    await independent.wait()
    #expect(await log.values == ["say:start", "default"])
    await release.open()
    try await executor.finish(inputID: input.id)
    #expect(await log.values == ["say:start", "default", "say:end", "same-channel"])
}

@Test func channelCountBoundRejectsNewLaneWithoutDroppingExistingWork() async throws {
    let release = ActionTestGate()
    let executor = ChannelScheduler(
        registry: ActionRegistry(handlers: [sayPath: { _ in await release.wait() }]), maximumChannels: 1)
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("one", input: input, channel: "main"))
    await #expect(throws: ActionExecutionError.channelCountExceeded) {
        try await executor.enqueue(path: sayPath, invocation: actionInvocation("two", input: input, channel: "other"))
    }
    await release.open()
    try await executor.finish(inputID: input.id)
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("three", input: input, channel: "other"))
    try await executor.finish(inputID: input.id)
}

@Test func samePhysicalModuleNeverOverlapsAcrossDifferentChannels() async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let log = ActionTestLog()
    let executor = ChannelScheduler(
        registry: ActionRegistry(handlers: [
            sayPath: { invocation in
                let text = invocation.call.parameters["text"] ?? ""
                await log.append("\(text):start")
                if text == "first" {
                    await started.open()
                    await release.wait()
                }
                await log.append("\(text):end")
            }
        ]))
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("first", input: input, channel: "main"))
    await started.wait()
    try await executor.enqueue(path: sayPath, invocation: actionInvocation("second", input: input, channel: "Speech"))
    #expect(await log.values == ["first:start"])
    await release.open()
    try await executor.finish(inputID: input.id)
    #expect(await log.values == ["first:start", "first:end", "second:start", "second:end"])
}

private func boundary(_ directive: SchedulingDirective, _ input: AgentInput) -> OutputEnvelope {
    OutputEnvelope(source: .assistant, input: input, output: .scheduling(directive))
}

@Test func waitGroupsJoinBeforeAndAfterWithoutBlockingIndependentTasks() async throws {
    let beforeStarted = ActionTestGate()
    let releaseBefore = ActionTestGate()
    let insideStarted = ActionTestGate()
    let releaseInside = ActionTestGate()
    let displayStarted = ActionTestGate()
    let releaseDisplay = ActionTestGate()
    let log = ActionTestLog()
    let scheduler = ChannelScheduler(
        registry: ActionRegistry(handlers: [
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
    try await scheduler.enqueue(path: sayPath, invocation: actionInvocation("before", input: input))
    await beforeStarted.wait()
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.enqueue(path: sayPath, invocation: actionInvocation("inside", input: input))
    try await scheduler.enqueue(path: printPath, invocation: actionInvocation("display", input: input, path: printPath))
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.enqueue(path: printPath, invocation: actionInvocation("after", input: input, path: printPath))
    // Dormant UI jobs do not obstruct another task using the same channel and module.
    try await scheduler.enqueue(path: printPath, invocation: actionInvocation("other", input: other, path: printPath))
    try await scheduler.finish(inputID: other.id)
    #expect(await log.values == ["before:start", "other:start", "other:end"])
    await releaseBefore.open()
    await insideStarted.wait()
    await displayStarted.wait()
    #expect(!(await log.values).contains("after:start"))
    await releaseInside.open()
    await releaseDisplay.open()
    try await scheduler.finish(inputID: input.id)
    let values = await log.values
    #expect(values.firstIndex(of: "after:start")! > values.firstIndex(of: "inside:end")!)
    #expect(values.firstIndex(of: "after:start")! > values.firstIndex(of: "display:end")!)
}

@Test func nestedWaitIsStreamingButUnclosedGroupCannotReleaseParentContinuation() async throws {
    let ran = ActionTestGate()
    let release = ActionTestGate()
    let log = ActionTestLog()
    let scheduler = ChannelScheduler(
        registry: ActionRegistry(handlers: [
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
    try await scheduler.enqueue(path: sayPath, invocation: actionInvocation("A", input: input))
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.enqueue(path: sayPath, invocation: actionInvocation("B", input: input))
    await ran.wait()  // Executes even before the inner group has closed.
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.enqueue(path: sayPath, invocation: actionInvocation("C", input: input))
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.enqueue(path: sayPath, invocation: actionInvocation("D", input: input))
    #expect(await log.values == ["A", "B"])
    await release.open()
    try await scheduler.finish(inputID: input.id)
    #expect(await log.values == ["A", "B", "C", "D"])
}

@Test func malformedSchedulesAndGroupCapacityFailAndCleanup() async throws {
    let scheduler = ChannelScheduler(registry: ActionRegistry(handlers: [:]))
    let input = AgentInput(sessionID: UUID(), payload: .text("limits"))
    await #expect(throws: ActionExecutionError.invalidSchedule) {
        try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    }
    for _ in 0..<32 {
        try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
        try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    }
    await #expect(throws: ActionExecutionError.waitGroupLimitExceeded) {
        try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    }
    try await scheduler.finish(inputID: input.id)
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    await #expect(throws: ActionExecutionError.invalidSchedule) { try await scheduler.finish(inputID: input.id) }
    for _ in 0..<8 { try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input)) }
    await #expect(throws: ActionExecutionError.waitGroupLimitExceeded) {
        try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    }
    await scheduler.cancel(inputID: input.id)
}

@Test func waitFailureCancelsDormantGroupsAndFencesLateAdmission() async throws {
    let started = ActionTestGate()
    let release = ActionTestGate()
    let log = ActionTestLog()
    let scheduler = ChannelScheduler(
        registry: ActionRegistry(handlers: [
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
    try await scheduler.enqueue(path: sayPath, invocation: actionInvocation("fail", input: input))
    await started.wait()
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await scheduler.enqueue(path: printPath, invocation: actionInvocation("dormant", input: input, path: printPath))
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    await release.open()
    // Acquiring the same module proves the failed handler was released and its task fenced.
    let probe = AgentInput(sessionID: UUID(), payload: .text("probe"))
    try await scheduler.enqueue(path: sayPath, invocation: actionInvocation("probe", input: probe))
    try await scheduler.finish(inputID: probe.id)
    await #expect(throws: ActionTestFailure.playback) {
        try await scheduler.enqueue(
            path: printPath, invocation: actionInvocation("late", input: input, path: printPath))
    }
    await #expect(throws: ActionTestFailure.playback) { try await scheduler.finish(inputID: input.id) }
    #expect(await log.values.isEmpty)
}

@Test func nestedWaitCancellationJoinsRunningCleanupAndDropsFuturePhases() async throws {
    let started = ActionTestGate()
    let cancelling = ActionTestGate()
    let release = ActionTestGate()
    let log = ActionTestLog()
    let scheduler = ChannelScheduler(
        registry: ActionRegistry(handlers: [
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
    try await scheduler.enqueue(path: sayPath, invocation: actionInvocation("active", input: input))
    await started.wait()
    try await scheduler.schedule(.endWait, envelope: boundary(.endWait, input))
    try await scheduler.enqueue(
        path: printPath, invocation: actionInvocation("must not run", input: input, path: printPath))
    let cancellation = Task {
        await scheduler.cancel(inputID: input.id)
        await log.append("cancel returned")
    }
    await cancelling.wait()
    #expect(await log.values.isEmpty)
    let other = AgentInput(sessionID: UUID(), payload: .text("other"))
    try await scheduler.enqueue(path: printPath, invocation: actionInvocation("other", input: other, path: printPath))
    try await scheduler.finish(inputID: other.id)
    #expect(await log.values == ["other"])
    await release.open()
    await cancellation.value
    #expect(await log.values == ["other", "cleaned", "cancel returned"])
}

@Test func dormantActionsCountTowardGlobalChannelAndTaskBounds() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("bounds"))
    let scheduler = ChannelScheduler(registry: ActionRegistry(handlers: [sayPath: { _ in }]), capacityPerChannel: 128)
    for _ in 0..<120 {
        try await scheduler.enqueue(path: sayPath, invocation: actionInvocation("text", input: input))
    }
    await #expect(throws: ActionExecutionError.taskActionLimitExceeded) {
        try await scheduler.enqueue(path: sayPath, invocation: actionInvocation("excess", input: input))
    }
    try await scheduler.finish(inputID: input.id)

    let release = ActionTestGate()
    let bounded = ChannelScheduler(
        registry: ActionRegistry(handlers: [sayPath: { _ in await release.wait() }, printPath: { _ in }]),
        capacityPerChannel: 1)
    try await bounded.enqueue(path: sayPath, invocation: actionInvocation("before", input: input))
    try await bounded.schedule(.beginWait, envelope: boundary(.beginWait, input))
    try await bounded.enqueue(path: printPath, invocation: actionInvocation("dormant", input: input, path: printPath))
    let other = AgentInput(sessionID: UUID(), payload: .text("other"))
    await #expect(throws: ActionExecutionError.channelCapacityExceeded("UI")) {
        try await bounded.enqueue(
            path: printPath, invocation: actionInvocation("overflow", input: other, path: printPath))
    }
    await release.open()
    await bounded.cancel(inputID: input.id)
}
