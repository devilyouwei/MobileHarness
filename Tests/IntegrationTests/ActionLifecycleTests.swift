import Actions
import AgentCore
import Agents
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import Testing

private actor LifecycleGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation {
            precondition(waiters.count < 8)
            waiters.append($0)
        }
    }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor LifecycleCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor LifecyclePermitBox {
    private var value: ResourceExecutionPermit?
    func capture(_ permit: ResourceExecutionPermit?) { value = permit }
    func get() -> ResourceExecutionPermit? { value }
}

private actor ReceiptAgent: Agent {
    nonisolated let descriptor: AgentDescriptor
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    private var lifecycle: AgentLifecycle = .registered
    private var inbox = ActionResultInbox()
    private(set) var activities: [ActivityEvent] = []
    private(set) var lastInput: AgentInput?
    private var rejectOnce: Bool

    init(id: AgentID = .assistant, rejectOnce: Bool = false, capabilities: CapabilityRegistry? = nil) throws {
        self.rejectOnce = rejectOnce
        descriptor = AgentDescriptor(
            id: id, name: "Receipt fixture", inputs: [.actionResult, .activityEvent],
            outputs: [.actionCall, .toolCall],
            capabilities: try capabilities ?? CapabilityRegistry())
    }
    func start() { lifecycle = .running }
    func pause() { lifecycle = .paused }
    func resume() { lifecycle = .running }
    func stop() { lifecycle = .stopped }
    func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: inbox.results.count)
    }
    func receive(_ input: AgentInput) throws {
        guard lifecycle == .running else { throw HarnessError.notRunning }
        if rejectOnce {
            rejectOnce = false
            throw HarnessError.queueFull
        }
        switch input.payload {
        case .actionResult(let result): inbox.accept(result)
        case .activityEvent(let event):
            guard activities.count < 8 else { throw HarnessError.queueFull }
            activities.append(event)
        default: throw HarnessError.unsupportedInput
        }
        lastInput = input
    }
    func results() -> [ActionResult] { inbox.results }
}

private let lifecyclePath = ActionPath(domain: "Device", module: "Control", function: "perform")
private let armResource = ResourceID(rawValue: "robot.arm")
private let secondResource = ResourceID(rawValue: "robot.head")
private let otherAgent = AgentID(rawValue: "other")

private func lifecycleIsLocked(_ state: ResourceCoordinator.State?) -> Bool {
    if case .locked? = state { return true }
    return false
}

private func lifecycleOwner(_ agent: AgentID = .assistant) -> ExecutionOwner {
    ExecutionOwner(agent: agent, incarnation: UUID(), sessionID: UUID())
}

private func lifecycleInvocation(
    owner: ExecutionOwner, path: ActionPath = lifecyclePath, lease: ResourceLease? = nil,
    feedback: ActionFeedback = .terminal
) throws -> ScheduledAction {
    try ScheduledAction(
        envelope: OutputEnvelope(
            source: owner.agent, input: AgentInput(sessionID: owner.sessionID, payload: .event("test")),
            output: .actionCall(ActionCall(actionPath: path, channel: "Ordered"))),
        owner: owner, feedback: feedback, lease: lease)
}

private func lifecycleResources(stop: @escaping @Sendable () async throws -> Void = {}) throws -> ResourceCoordinator {
    try ResourceCoordinator(definitions: [
        ResourceDefinition(id: armResource, allowedOwners: [.assistant, otherAgent], stop: stop),
        ResourceDefinition(id: secondResource, allowedOwners: [.assistant, otherAgent], stop: {}),
    ])
}

@Test(.timeLimit(.minutes(1))) func failedResourceUseUnlocksAndOldPermitCannotAffectNewOwner() async throws {
    let resources = try lifecycleResources()
    let permitBox = LifecyclePermitBox()
    let first = lifecycleOwner()
    await #expect(throws: HarnessError.notRunning) {
        try await resources.run(resources: [armResource], owner: first, lease: nil) {
            #expect(await resources.snapshot()[armResource] == .locked(first))
            await permitBox.capture(ResourceExecutionContext.permit)
            throw HarnessError.notRunning
        }
    }
    #expect(await resources.snapshot()[armResource] == .unlocked)
    let started = LifecycleGate()
    let finish = LifecycleGate()
    let next = lifecycleOwner(otherAgent)
    let running = Task {
        try await resources.run(resources: [armResource], owner: next, lease: nil) {
            await started.release()
            await finish.wait()
        }
    }
    await started.wait()
    let oldPermit = try #require(await permitBox.get())
    await #expect(throws: ResourceError.staleUse) { try await oldPermit.validate([armResource]) }
    #expect(await resources.snapshot()[armResource] == .locked(next))
    await finish.release()
    try await running.value
    #expect(await resources.snapshot()[armResource] == .unlocked)
}

@Test func cancelledResourceExecutionReleasesWithoutReportingSuccess() async throws {
    let resources = try lifecycleResources()
    await #expect(throws: CancellationError.self) {
        try await resources.run(resources: [armResource], owner: lifecycleOwner(), lease: nil) {
            // A native/custom handler may return without checking its cancellation signal.
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    #expect(await resources.snapshot()[armResource] == .unlocked)
    try await resources.run(resources: [armResource], owner: lifecycleOwner(), lease: nil) {}
}

@Test(.timeLimit(.minutes(1))) func stopErrorAfterWriterJoinDoesNotPreventNextResourceUse() async throws {
    let resources = try ResourceCoordinator(definitions: [
        ResourceDefinition(
            id: armResource, allowedOwners: [.assistant, .photographer], preempts: [.assistant: [.photographer]]
        ) { throw HarnessError.notRunning }
    ])
    let started = LifecycleGate()
    let old = Task {
        try await resources.run(resources: [armResource], owner: lifecycleOwner(.photographer), lease: nil) {
            await started.release()
            try await Task.sleep(for: .seconds(60))
        }
    }
    await started.wait()
    let executions = LifecycleCounter()
    await #expect(throws: HarnessError.notRunning) {
        try await resources.run(resources: [armResource], owner: lifecycleOwner(), lease: nil) {
            await executions.increment()
        }
    }
    _ = await old.result
    #expect(await executions.value == 0)
    #expect(await resources.snapshot()[armResource] == .unlocked)
    try await resources.run(resources: [armResource], owner: lifecycleOwner(), lease: nil) {
        await executions.increment()
    }
    #expect(await executions.value == 1)
}

@Test(.timeLimit(.minutes(1)), arguments: ["agent", "session", "shutdown"])
func cancelledResourceOwnerCleanupWaitsForAcknowledgmentAndAllowsAssistant(scope: String) async throws {
    let started = LifecycleGate()
    let stopping = LifecycleGate()
    let finishStop = LifecycleGate()
    let completed = LifecycleCounter()
    let owner = lifecycleOwner(.photographer)
    let resources = try ResourceCoordinator(
        definitions: [armResource, secondResource].map {
            ResourceDefinition(
                id: $0, allowedOwners: [.assistant, .photographer], executionGroup: armResource,
                preempts: [.assistant: [.photographer]]
            ) {
                await stopping.release()
                await finishStop.wait()
            }
        })
    let use = Task {
        try await resources.run(resources: [armResource], owner: owner, lease: nil) {
            await started.release()
            try await Task.sleep(for: .seconds(60))
        }
    }
    await started.wait()
    let closing = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        switch scope {
        case "agent": await resources.close(agent: owner.agent, incarnation: owner.incarnation)
        case "session": await resources.close(sessionID: owner.sessionID)
        default: await resources.shutdown()
        }
        await completed.increment()
    }
    await stopping.wait()
    #expect(await completed.value == 0)
    #expect(await resources.snapshot()[armResource] == .locked(owner))
    await finishStop.release()
    await closing.value
    _ = await use.result
    #expect(await resources.snapshot()[armResource] == .unlocked)
    if scope != "shutdown" {
        try await resources.run(resources: [secondResource], owner: lifecycleOwner(), lease: nil) {}
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["release", "acquire"])
func cancelledLeaseCleanupPreservesAcknowledgedUnlock(operation: String) async throws {
    let stops = LifecycleCounter()
    let stopping = LifecycleGate()
    let finishStop = LifecycleGate()
    let resources = try lifecycleResources {
        await stops.increment()
        if await stops.value > 1 {
            await stopping.release()
            await finishStop.wait()
        }
    }
    let owner = lifecycleOwner()
    let lease = try await resources.acquire(resources: [armResource], owner: owner, duration: .seconds(10)) { _ in }
    let cleanup = Task {
        if operation == "release" {
            try await resources.release(lease, owner: owner)
        } else {
            _ = try await resources.acquire(
                resources: [armResource], owner: lifecycleOwner(otherAgent), duration: .seconds(10)
            ) { _ in }
        }
    }
    await stopping.wait()
    cleanup.cancel()
    #expect(await resources.snapshot()[armResource] == .locked(owner))
    await finishStop.release()
    if operation == "release" {
        try await cleanup.value
    } else {
        await #expect(throws: CancellationError.self) { try await cleanup.value }
    }
    #expect(await resources.snapshot()[armResource] == .unlocked)
    #expect(await resources.lease(for: owner, resources: [armResource]) == nil)
    try await resources.run(resources: [armResource], owner: lifecycleOwner(), lease: nil) {}
}

@Test(.timeLimit(.minutes(1))) func cancelledVisionOwnerRemovalAllowsNextAssistantAction() async throws {
    let started = LifecycleGate()
    let stopping = LifecycleGate()
    let finishStop = LifecycleGate()
    let actions = LifecycleCounter()
    let resources = try ResourceCoordinator(definitions: [
        ResourceDefinition(id: armResource, allowedOwners: [.assistant, .photographer]) {
            await stopping.release()
            await finishStop.wait()
        }
    ])
    let manager = AgentManager()
    let visionSession = UUID()
    let replySession = UUID()
    try await manager.register(ReceiptAgent(id: .photographer), sessionID: visionSession)
    try await manager.start(.photographer)
    let assistant = try ReceiptAgent(
        capabilities: CapabilityRegistry(actions: [
            ActionRegistration(alias: "perform", path: lifecyclePath, defaultChannel: "Ordered")
        ]))
    try await manager.register(assistant, sessionID: replySession)
    try await manager.start(.assistant)
    let registry = try ActionRegistry(definitions: [
        ActionBinding(
            path: lifecyclePath, displayName: "Test move", kind: .finite, completion: "Acknowledged.",
            resources: [armResource]
        ) { _ in await actions.increment() }
    ])
    let scheduler = ChannelScheduler(registry: registry, resources: resources)
    let output = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, allowsExternalSend: true), tools: ToolRegistry(),
        actions: scheduler, sink: { _ in })
    _ = try await output.resourceControl(for: .photographer, sessionID: visionSession)
    let owner = ExecutionOwner(
        agent: .photographer, incarnation: try await manager.identity(.photographer), sessionID: visionSession)
    let tracking = Task {
        try await resources.run(resources: [armResource], owner: owner, lease: nil) {
            await started.release()
            try await Task.sleep(for: .seconds(60))
        }
    }
    await started.wait()
    // CameraCoordinator cancels VisionSession before its catch removes the Photographer.
    let closeCamera = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await manager.remove(.photographer)
    }
    await stopping.wait()
    #expect(await resources.snapshot()[armResource] == .locked(owner))
    #expect(await actions.value == 0)
    await finishStop.release()
    try await closeCamera.value
    _ = await tracking.result
    let parent = AgentInput(sessionID: replySession, payload: .event("move"))
    try await output.dispatch(
        OutputEnvelope(
            source: .assistant, input: parent,
            output: .actionCall(ActionCall(actionPath: lifecyclePath, channel: "Ordered"))))
    try await scheduler.finish(inputID: parent.id, source: .assistant)
    #expect(await actions.value == 1)
    #expect(await scheduler.diagnosticSnapshot().records.last?.phase == .succeeded)
    #expect(await resources.snapshot()[armResource] == .unlocked)
    #expect(await assistant.status().lifecycle == .running)
    await output.shutdown()
}

@Test(.timeLimit(.minutes(1))) func cancelledOwnerCleanupTimeoutEventuallyUnlocks() async throws {
    let started = LifecycleGate()
    let finishStop = LifecycleGate()
    let owner = lifecycleOwner(.photographer)
    let resources = try ResourceCoordinator(
        definitions: [
            ResourceDefinition(id: armResource, allowedOwners: [.assistant, .photographer]) {
                await finishStop.wait()
            }
        ], cleanupDeadline: .milliseconds(30))
    let tracking = Task {
        try await resources.run(resources: [armResource], owner: owner, lease: nil) {
            await started.release()
            try await Task.sleep(for: .seconds(60))
        }
    }
    await started.wait()
    let closing = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await resources.close(sessionID: owner.sessionID)
    }
    await closing.value
    #expect(await resources.snapshot()[armResource] == .locked(owner))
    #expect(await resources.activeCleanupCount() == 1)
    await #expect(throws: ResourceError.busy) {
        try await resources.run(resources: [armResource], owner: lifecycleOwner(), lease: nil) {}
    }
    await finishStop.release()
    _ = await tracking.result
    for _ in 0..<10000 {
        if await resources.activeCleanupCount() == 0 { break }
        await Task.yield()
    }
    #expect(await resources.activeCleanupCount() == 0)
    #expect(await resources.snapshot()[armResource] == .unlocked)
    try await resources.run(resources: [armResource], owner: lifecycleOwner(), lease: nil) {}
}

@Test(.timeLimit(.minutes(1))) func resourcePreemptionJoinsOldWriterAndRejectsReverseTakeover() async throws {
    let permitBox = LifecyclePermitBox()
    let group = ResourceID(rawValue: "device.writer")
    let resources = try ResourceCoordinator(
        definitions: [armResource, secondResource].map {
            ResourceDefinition(
                id: $0, allowedOwners: [.assistant, .photographer], executionGroup: group,
                preempts: [.assistant: [.photographer]]
            ) {}
        })
    let started = LifecycleGate()
    let cleaning = LifecycleGate()
    let releaseCleanup = LifecycleGate()
    let admitted = LifecycleGate()
    let releaseAssistant = LifecycleGate()
    let count = LifecycleCounter()
    let old = Task {
        try await resources.run(resources: [armResource], owner: lifecycleOwner(.photographer), lease: nil) {
            await permitBox.capture(ResourceExecutionContext.permit)
            await started.release()
            do { try await Task.sleep(for: .seconds(60)) } catch {
                await cleaning.release()
                await releaseCleanup.wait()
                throw error
            }
        }
    }
    await started.wait()
    // A disjoint ID still shares the same physical writer.
    let assistant = Task {
        try await resources.run(resources: [secondResource], owner: lifecycleOwner(), lease: nil) {
            await count.increment()
            await admitted.release()
            await releaseAssistant.wait()
        }
    }
    await cleaning.wait()
    #expect(await count.value == 0)
    #expect(await resources.snapshot().values.allSatisfy { lifecycleIsLocked($0) })
    let oldPermit = try #require(await permitBox.get())
    await #expect(throws: ResourceError.staleUse) { try await oldPermit.validate([armResource]) }
    await #expect(throws: ResourceError.busy) {
        try await resources.run(resources: [armResource], owner: lifecycleOwner(.photographer), lease: nil) {}
    }
    await releaseCleanup.release()
    await admitted.wait()
    await #expect(throws: CancellationError.self) { try await old.value }
    await #expect(throws: ResourceError.busy) {
        try await resources.run(resources: [armResource], owner: lifecycleOwner(.photographer), lease: nil) {}
    }
    await #expect(throws: ResourceError.busy) {
        try await resources.run(resources: [armResource], owner: lifecycleOwner(), lease: nil) {}
    }
    await releaseAssistant.release()
    try await assistant.value
    try await resources.run(resources: [armResource], owner: lifecycleOwner(.photographer), lease: nil) {}
}

@Test(.timeLimit(.minutes(1))) func resourcePreemptionTimeoutKeepsWholeWriterLockedUntilJoin() async throws {
    let started = LifecycleGate()
    let releaseCleanup = LifecycleGate()
    let count = LifecycleCounter()
    let resources = try ResourceCoordinator(
        definitions: [armResource, secondResource].map {
            ResourceDefinition(
                id: $0, allowedOwners: [.assistant, .photographer], executionGroup: armResource,
                preempts: [.assistant: [.photographer]]
            ) {}
        }, cleanupDeadline: .milliseconds(30))
    let old = Task {
        try await resources.run(resources: [armResource], owner: lifecycleOwner(.photographer), lease: nil) {
            await started.release()
            do { try await Task.sleep(for: .seconds(60)) } catch {
                await releaseCleanup.wait()
                throw error
            }
        }
    }
    await started.wait()
    await #expect(throws: ResourceError.cleanupTimedOut) {
        try await resources.run(resources: [secondResource], owner: lifecycleOwner(), lease: nil) {
            await count.increment()
        }
    }
    #expect(await count.value == 0)
    #expect(await resources.snapshot().values.allSatisfy { lifecycleIsLocked($0) })
    await #expect(throws: ResourceError.busy) {
        try await resources.run(resources: [secondResource], owner: lifecycleOwner(), lease: nil) {}
    }
    await releaseCleanup.release()
    _ = await old.result
    for _ in 0..<100 {
        if await resources.activeCleanupCount() == 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await resources.activeCleanupCount() == 0)
    #expect(await resources.snapshot().values.allSatisfy { $0 == .unlocked })
    try await resources.run(resources: [secondResource], owner: lifecycleOwner(), lease: nil) {
        await count.increment()
    }
    #expect(await count.value == 1)
}

@Test(.timeLimit(.minutes(1))) func actionResultsRetryDeliveryWithoutRepeatingEffects() async throws {
    let manager = AgentManager()
    let agent = try ReceiptAgent(rejectOnce: true)
    let session = UUID()
    try await manager.register(agent, sessionID: session)
    try await manager.start(.assistant)
    let owner = ExecutionOwner(
        agent: .assistant, incarnation: try await manager.identity(.assistant), sessionID: session)
    let input = InputGateway(manager: manager, allowsExternalSend: true)
    let counter = LifecycleCounter()
    let registry = try ActionRegistry(definitions: [
        ActionBinding(path: lifecyclePath, displayName: "测试动作", kind: .finite, completion: "Effect completed.") {
            _ in
            await counter.increment()
        }
    ])
    let scheduler = ChannelScheduler(registry: registry) { await input.deliverActionResult($0) }
    let invocation = try lifecycleInvocation(owner: owner)
    let execution = try await scheduler.enqueue(invocation: invocation)
    try await scheduler.finish(inputID: invocation.envelope.inputID, source: AgentID(rawValue: "assistant"))
    await scheduler.finishResultDelivery()
    let results = await agent.results()
    #expect(results.count == 1 && results.first?.executionID == execution)
    #expect(results.first?.status == .succeeded && results.first?.effect == .contractCompleted)
    #expect(await counter.value == 1)
    #expect(await scheduler.resultSnapshot().last?.delivery == "accepted")
    if let result = results.first {
        #expect(await input.deliverActionResult(result) == .accepted)
        #expect(await agent.results().count == 1)
        await #expect(throws: CommunicationError.unauthorized) {
            try await input.send(AgentInput(sessionID: session, payload: .actionResult(result)), to: .assistant)
        }
    }
}

@Test func resultAndActivityDeliveryNeverCrossAgentIncarnations() async throws {
    let manager = AgentManager()
    let old = try ReceiptAgent()
    let session = UUID()
    try await manager.register(old, sessionID: session)
    try await manager.start(.assistant)
    let owner = ExecutionOwner(
        agent: .assistant, incarnation: try await manager.identity(.assistant), sessionID: session)
    try await manager.remove(.assistant)
    let replacement = try ReceiptAgent()
    try await manager.register(replacement, sessionID: session)
    try await manager.start(.assistant)
    let input = InputGateway(manager: manager, allowsExternalSend: true)
    let result = ActionResult(
        executionID: UUID(), owner: owner, path: lifecyclePath, causality: .root(),
        status: .succeeded, effect: .contractCompleted, completion: .completed)
    #expect(await input.deliverActionResult(result) == .closed)
    #expect(
        await input.deliverActivityEvent(
            ActivityEvent(activityID: UUID(), owner: owner, state: .failed, sequence: 1, causality: .root()))
            == .closed)
    #expect(await replacement.results().isEmpty)
    #expect(await replacement.activities.isEmpty)
    let current = ExecutionOwner(
        agent: .assistant, incarnation: try await manager.identity(.assistant), sessionID: session)
    #expect(
        await input.deliverActivityEvent(
            ActivityEvent(activityID: UUID(), owner: current, state: .started, sequence: 1, causality: .root()))
            == .accepted)
}

@Test(.timeLimit(.minutes(1))) func terminalSlotIsReservedBeforeActionAdmissionAndDoesNotHoldLane() async throws {
    let deliveryStarted = LifecycleGate()
    let releaseDelivery = LifecycleGate()
    let counter = LifecycleCounter()
    let registry = try ActionRegistry(definitions: [
        ActionBinding(path: lifecyclePath, displayName: "测试动作", kind: .state, completion: "State committed.") { _ in
            await counter.increment()
        }
    ])
    let scheduler = ChannelScheduler(registry: registry, resultCapacity: 1) { _ in
        await deliveryStarted.release()
        await releaseDelivery.wait()
        return .accepted
    }
    let owner = lifecycleOwner()
    let first = try lifecycleInvocation(owner: owner)
    try await scheduler.enqueue(invocation: first)
    try await scheduler.finish(inputID: first.envelope.inputID, source: AgentID(rawValue: "assistant"))
    await deliveryStarted.wait()
    await #expect(throws: ActionSchedulingError.resultCapacityExceeded) {
        try await scheduler.enqueue(invocation: lifecycleInvocation(owner: owner))
    }
    let noFeedback = try lifecycleInvocation(owner: owner, feedback: .none)
    try await scheduler.enqueue(invocation: noFeedback)
    try await scheduler.finish(inputID: noFeedback.envelope.inputID, source: AgentID(rawValue: "assistant"))
    #expect(await counter.value == 2)
    await releaseDelivery.release()
    await scheduler.finishResultDelivery()
}

@Test func activityStartReturnsAHandleWithoutWaitingForActivityTermination() async throws {
    let activityID = UUID()
    let registry = try ActionRegistry(definitions: [
        ActionBinding(
            path: lifecyclePath, displayName: "测试动作", kind: .activityStart, completion: "Capture active.",
            completing: { _ in
                .activityStarted(activityID)
            })
    ])
    let scheduler = ChannelScheduler(registry: registry) { _ in .accepted }
    let invocation = try lifecycleInvocation(owner: lifecycleOwner())
    try await scheduler.enqueue(invocation: invocation)
    try await scheduler.finish(inputID: invocation.envelope.inputID, source: AgentID(rawValue: "assistant"))
    await scheduler.finishResultDelivery()
    #expect(await scheduler.resultSnapshot().last?.result?.completion == .activityStarted(activityID))
}

@Test func resourceGroupsRejectUnauthorizedPartialAcquisitionAndStaleRelease() async throws {
    let resources = try lifecycleResources()
    let owner = lifecycleOwner()
    await #expect(throws: ResourceError.unknownResource) {
        try await resources.acquire(
            resources: [armResource, ResourceID(rawValue: "missing")], owner: owner, duration: .seconds(10)
        ) { _ in }
    }
    #expect(await resources.snapshot()[armResource] == .unlocked)
    await #expect(throws: ResourceError.unauthorized) {
        try await resources.acquire(
            resources: [armResource], owner: lifecycleOwner(AgentID(rawValue: "forbidden")), duration: .seconds(10)
        ) { _ in }
    }
    let revocations = LifecycleCounter()
    let first = try await resources.acquire(
        resources: [armResource, secondResource], owner: owner, duration: .seconds(10)
    ) { _ in await revocations.increment() }
    let replacementOwner = lifecycleOwner(otherAgent)
    let replacement = try await resources.acquire(
        resources: [armResource], owner: replacementOwner, duration: .seconds(10)
    ) { _ in }
    #expect(await resources.snapshot()[secondResource] == .unlocked)
    #expect(await revocations.value == 2)  // Initial gate and subsequent owner revocation.
    await #expect(throws: ResourceError.staleLease) { try await resources.release(first, owner: owner) }
    #expect(await resources.snapshot()[armResource] == .locked(replacementOwner))
    await #expect(throws: ResourceError.staleLease) {
        try await resources.renew(replacement, owner: owner, duration: .seconds(10))
    }
    try await resources.release(replacement, owner: replacementOwner)
}

private actor RevocationDevice {
    let running = LifecycleGate()
    let stopped = LifecycleGate()
    private var active = false
    private(set) var starts = 0
    func perform() async throws {
        starts += 1
        active = true
        await running.release()
        await stopped.wait()
        try Task.checkCancellation()
    }
    func stop() async {
        if active {
            active = false
            await stopped.release()
        }
    }
}

@Test(.timeLimit(.minutes(1))) func takeoverCancelsQueuedWorkAndJoinsDeviceStopBeforeGrant() async throws {
    let device = RevocationDevice()
    let resources = try lifecycleResources { await device.stop() }
    let registry = try ActionRegistry(definitions: [
        ActionBinding(
            path: lifecyclePath, displayName: "测试动作", kind: .finite, completion: "Device stopped.",
            resources: [armResource]
        ) {
            _ in
            try await device.perform()
        }
    ])
    let scheduler = ChannelScheduler(registry: registry, resources: resources)
    let owner = lifecycleOwner()
    let lease = try await resources.acquire(resources: [armResource], owner: owner, duration: .seconds(10)) {
        await scheduler.cancel(resources: $0)
    }
    let invocation = try lifecycleInvocation(owner: owner, lease: lease, feedback: .none)
    try await scheduler.enqueue(invocation: invocation)
    await device.running.wait()
    try await scheduler.enqueue(invocation: invocation)
    let next = lifecycleOwner(otherAgent)
    let replacement = try await resources.acquire(resources: [armResource], owner: next, duration: .seconds(10)) {
        await scheduler.cancel(resources: $0)
    }
    #expect(await device.starts == 1)
    #expect(await resources.snapshot()[armResource] == .locked(next))
    #expect(await scheduler.diagnosticSnapshot().records.filter { $0.phase == .cancelled }.count == 2)
    await #expect(throws: ResourceError.staleLease) {
        try await scheduler.enqueue(invocation: invocation)
    }
    try await resources.release(replacement, owner: next)
}

@Test(.timeLimit(.minutes(1))) func cleanupTimeoutKeepsLockOnlyUntilActualCleanupFinishes() async throws {
    let releaseStop = LifecycleGate()
    let resources = try ResourceCoordinator(
        definitions: [
            ResourceDefinition(id: armResource, allowedOwners: [.assistant]) { await releaseStop.wait() }
        ], cleanupDeadline: .milliseconds(20))
    await #expect(throws: ResourceError.cleanupTimedOut) {
        try await resources.acquire(resources: [armResource], owner: lifecycleOwner(), duration: .seconds(10)) { _ in }
    }
    #expect(lifecycleIsLocked(await resources.snapshot()[armResource]))
    await #expect(throws: ResourceError.busy) {
        _ = try await resources.acquire(resources: [armResource], owner: lifecycleOwner(), duration: .seconds(10)) {
            _ in
        }
    }
    await releaseStop.release()
    for _ in 0..<10000 {
        if await resources.activeCleanupCount() == 0 { break }
        await Task.yield()
    }
    #expect(await resources.activeCleanupCount() == 0)
    #expect(await resources.snapshot()[armResource] == .unlocked)
    let owner = lifecycleOwner()
    let lease = try await resources.acquire(resources: [armResource], owner: owner, duration: .seconds(10)) { _ in }
    try await resources.release(lease, owner: owner)
}

@Test(.timeLimit(.minutes(1))) func leasesExpireAndStopWithoutAnotherCaller() async throws {
    let expirationStop = LifecycleGate()
    let count = LifecycleCounter()
    let resources = try lifecycleResources {
        await count.increment()
        if await count.value > 1 { await expirationStop.release() }
    }
    let owner = lifecycleOwner()
    let lease = try await resources.acquire(resources: [armResource], owner: owner, duration: .milliseconds(20)) { _ in
    }
    await expirationStop.wait()
    for _ in 0..<10000 {
        if await resources.snapshot()[armResource] == .unlocked { break }
        await Task.yield()
    }
    #expect(await resources.snapshot()[armResource] == .unlocked)
    await #expect(throws: ResourceError.staleLease) {
        try await resources.renew(lease, owner: owner, duration: .seconds(1))
    }
}

@Test func protectedToolResolvesSharedDefinitionResourcesBeforeExecution() async throws {
    let resources = try lifecycleResources()
    let original = lifecycleOwner()
    let lease = try await resources.acquire(resources: [armResource], owner: original, duration: .seconds(10)) { _ in }
    let manager = AgentManager()
    let capabilities = try CapabilityRegistry(tools: [ToolRegistration(alias: "move", path: "Fixture.Control.move")])
    let agent = try ReceiptAgent(id: otherAgent, capabilities: capabilities)
    let session = UUID()
    try await manager.register(agent, sessionID: session)
    try await manager.start(otherAgent)
    let input = InputGateway(manager: manager, allowsExternalSend: true)
    let count = LifecycleCounter()
    let definition = ActionBinding(
        path: .init(domain: "Fixture", module: "Control", function: "move"), displayName: "Move",
        kind: .finite, completion: "Effect accepted.", protocols: [.tool], executionPolicy: .direct,
        resolvingResources: { _ in [ActionResource(rawValue: armResource.rawValue)] },
        handler: { _ in await count.increment() })
    let tools = try ToolRegistry(modules: [DynamicResourceToolFixture(definitions: [definition])])
    let output = OutputGateway(
        manager: manager, requests: input, tools: tools,
        actions: ChannelScheduler(registry: ActionRegistry(), resources: resources), sink: { _ in })
    await #expect(throws: ResourceError.staleLease) {
        try await output.dispatch(
            OutputEnvelope(
                source: otherAgent, input: AgentInput(sessionID: session, payload: .event("test")),
                output: .toolCall(ToolCall(toolPath: "Fixture.Control.move", arguments: [:]))))
    }
    #expect(await count.value == 0)
    try await resources.release(lease, owner: original)
}

@Test func controlPortsAreBoundToTheirAgentIncarnation() async throws {
    let resources = try lifecycleResources()
    let manager = AgentManager()
    let agent = try ReceiptAgent()
    let session = UUID()
    try await manager.register(agent, sessionID: session)
    try await manager.start(.assistant)
    let output = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, allowsExternalSend: true), tools: ToolRegistry(),
        actions: ChannelScheduler(registry: ActionRegistry(), resources: resources), sink: { _ in })
    let control = try await output.resourceControl(for: .assistant, sessionID: session)
    let lease = try await control.acquire([armResource], .seconds(10))
    try await manager.remove(.assistant)
    await #expect(throws: CommunicationError.staleIncarnation) { try await control.renew(lease, .seconds(10)) }
    // AgentManager stop hooks automatically clean the lease; stale release cannot affect later owners.
    await #expect(throws: ResourceError.staleLease) { try await control.release(lease) }
    #expect(await resources.snapshot()[armResource] == .unlocked)
}

@Test(.timeLimit(.minutes(1))) func sessionCloseStopsResourceBeforeJoiningCancelledHandler() async throws {
    let device = RevocationDevice()
    let resources = try lifecycleResources { await device.stop() }
    let registry = try ActionRegistry(definitions: [
        ActionBinding(
            path: lifecyclePath, displayName: "测试动作", kind: .finite, completion: "Device stopped.",
            resources: [armResource]
        ) {
            _ in
            try await device.perform()
        }
    ])
    let scheduler = ChannelScheduler(registry: registry, resources: resources)
    let manager = AgentManager()
    let output = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, allowsExternalSend: true), tools: ToolRegistry(),
        actions: scheduler, sink: { _ in })
    let owner = lifecycleOwner()
    try await scheduler.enqueue(invocation: lifecycleInvocation(owner: owner, feedback: .none))
    await device.running.wait()
    await output.cancel(sessionID: owner.sessionID)
    #expect(await resources.snapshot()[armResource] == .unlocked)
    #expect(await scheduler.diagnosticSnapshot().records.last?.phase == .cancelled)
}

@Test func activityCompletionMustMatchItsRegisteredKind() async throws {
    let registry = try ActionRegistry(definitions: [
        ActionBinding(
            path: lifecyclePath, displayName: "测试动作", kind: .finite, completion: "Finite operation.",
            completing: { _ in
                .activityStarted(UUID())
            })
    ])
    await #expect(throws: ActionExecutionError.invalidCompletion) {
        try await ActionExecutor(registry: registry).execute(lifecycleInvocation(owner: lifecycleOwner()))
    }
}

@Test func failedActionReportsReachTheAgentWithoutAllowingSuccessOnlyCompletion() async throws {
    let manager = AgentManager()
    let agent = try ReceiptAgent()
    let session = UUID()
    try await manager.register(agent, sessionID: session)
    try await manager.start(.assistant)
    let owner = ExecutionOwner(
        agent: .assistant, incarnation: try await manager.identity(.assistant), sessionID: session)
    let input = InputGateway(manager: manager, allowsExternalSend: true)
    let registry = try ActionRegistry(definitions: [
        ActionBinding(
            path: lifecyclePath, displayName: "Simulated failure", kind: .finite, completion: "Report retained.",
            completing: { _ in
                .report(ActionReport.failure(.handlerFailed))
            })
    ])
    let scheduler = ChannelScheduler(registry: registry) { await input.deliverActionResult($0) }
    let invocation = try lifecycleInvocation(owner: owner)
    _ = try await scheduler.enqueue(invocation: invocation)
    try await scheduler.finish(inputID: invocation.envelope.inputID, source: owner.agent)
    await scheduler.finishResultDelivery()
    let results = await agent.results()
    #expect(results.count == 1 && results.first?.status == .failed)
    #expect(results.first?.report != nil && results.first?.failure == .handlerFailed)
    let invalid = ActionResult(
        executionID: UUID(), owner: owner, path: lifecyclePath, causality: .root(),
        status: .failed, effect: .unknown, completion: .completed, failure: .handlerFailed)
    #expect(await input.deliverActionResult(invalid) == .closed)
    #expect(await agent.results().count == 1)
    await scheduler.shutdown()
    try await manager.stop(.assistant)
}

private struct DynamicResourceToolFixture: ToolModule { let definitions: [ActionBinding] }

@Test func scheduledFeedbackPreservesInitiatingCausalChainAfterInputExpiry() async throws {
    let session = UUID()
    let agent = try ReceiptAgent()
    let manager = AgentManager()
    try await manager.register(agent, sessionID: session)
    try await manager.start(.assistant)
    let owner = ExecutionOwner(
        agent: .assistant, incarnation: try await manager.identity(.assistant), sessionID: session)
    let inputGateway = InputGateway(manager: manager, allowsExternalSend: true)
    let root = UUID()
    let turn = AgentTurn(ordinal: 9)
    let payload = InputPayload.event("fixture")
    let input = AgentInput(
        sessionID: session, payload: payload,
        metadata: .init(
            payload: payload, rootID: root, parentID: UUID(), hops: 3,
            deadline: .now.advanced(by: .seconds(-1))), turn: turn)
    let call = ActionCall(actionPath: lifecyclePath, channel: "main")
    let invocation = try ScheduledAction(
        envelope: .init(source: .assistant, input: input, output: .actionCall(call), sequence: 17),
        owner: owner, feedback: .terminal)
    let registry = try ActionRegistry(definitions: [
        ActionBinding(
            path: lifecyclePath, displayName: "Fixture", kind: .finite,
            completion: "Completed.", handler: { _ in })
    ])
    let scheduler = ChannelScheduler(registry: registry) { await inputGateway.deliverActionResult($0) }
    _ = try await scheduler.enqueue(invocation: invocation)
    try await scheduler.finish(inputID: input.id, source: .assistant)
    await scheduler.finishResultDelivery()
    let received = try #require(await agent.lastInput)
    #expect(received.metadata.rootID == root && received.metadata.parentID == input.id)
    #expect(received.metadata.hops == 4 && received.metadata.sequence == 17)
    #expect(received.turn == turn && received.metadata.origin == .runtime)
    #expect(!received.metadata.expired && received.id != input.id)
    #expect(await agent.results().first?.causality == SignalCausality(envelope: invocation.envelope))
    await scheduler.shutdown()
    try await manager.stop(.assistant)
}

@Test(arguments: [-1, 0, 7, 8]) func activityFeedbackPreservesCausalityAndClosesExhaustedHops(_ hops: Int) async throws
{
    let session = UUID()
    let agent = try ReceiptAgent()
    let manager = AgentManager()
    try await manager.register(agent, sessionID: session)
    try await manager.start(.assistant)
    let owner = ExecutionOwner(
        agent: .assistant, incarnation: try await manager.identity(.assistant), sessionID: session)
    let gateway = InputGateway(manager: manager, allowsExternalSend: true)
    let context = SignalCausality(inputID: UUID(), rootID: UUID(), hops: hops, turn: AgentTurn(ordinal: 3))
    let event = ActivityEvent(activityID: UUID(), owner: owner, state: .started, sequence: 12, causality: context)
    let result = await gateway.deliverActivityEvent(event)
    if (0..<8).contains(hops) {
        #expect(result == .accepted)
        let input = try #require(await agent.lastInput)
        #expect(input.metadata.rootID == context.rootID && input.metadata.parentID == context.inputID)
        #expect(input.metadata.hops == hops + 1 && input.metadata.sequence == 12 && input.turn == context.turn)
    } else {
        #expect(result == .closed)
        #expect(await agent.activities.isEmpty)
    }
    let action = ActionResult(
        executionID: UUID(), owner: owner, path: lifecyclePath, causality: context,
        status: .succeeded, effect: .contractCompleted, completion: .completed)
    #expect(await gateway.deliverActionResult(action) == ((0..<8).contains(hops) ? .accepted : .closed))
    try await manager.stop(.assistant)
}
