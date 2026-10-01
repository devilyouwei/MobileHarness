import Actions
import AgentCore
import Foundation
import Gateway
import Testing
import Tools

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

private actor ReceiptAgent: Agent {
    nonisolated let descriptor: AgentDescriptor
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    private var lifecycle: AgentLifecycle = .registered
    private var inbox = ActionResultInbox()
    private(set) var activities: [ActivityEvent] = []
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
    }
    func results() -> [ActionResult] { inbox.results }
}

private let lifecyclePath = ActionPath(module: "Device", function: "perform")
private let armResource = ResourceID(rawValue: "robot.arm")
private let secondResource = ResourceID(rawValue: "robot.head")
private let otherAgent = AgentID(rawValue: "other")

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

@Test(.timeLimit(.minutes(1))) func actionResultsRetryDeliveryWithoutRepeatingEffects() async throws {
    let manager = AgentManager()
    let agent = try ReceiptAgent(rejectOnce: true)
    let session = UUID()
    try await manager.register(agent, sessionID: session)
    try await manager.start(.assistant)
    let owner = ExecutionOwner(
        agent: .assistant, incarnation: try await manager.identity(.assistant), sessionID: session)
    let input = InputGateway(manager: manager)
    let counter = LifecycleCounter()
    let registry = try ActionRegistry(definitions: [
        ActionDefinition(path: lifecyclePath, displayName: "测试动作", kind: .finite, completion: "Effect completed.") {
            _ in
            await counter.increment()
        }
    ])
    let scheduler = ChannelScheduler(registry: registry) { await input.deliverActionResult($0) }
    let invocation = try lifecycleInvocation(owner: owner)
    let execution = try await scheduler.enqueue(invocation: invocation)
    try await scheduler.finish(inputID: invocation.envelope.inputID)
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
    let input = InputGateway(manager: manager)
    let result = ActionResult(
        executionID: UUID(), owner: owner, inputID: UUID(), turn: nil, path: lifecyclePath,
        status: .succeeded, effect: .contractCompleted, completion: .completed)
    #expect(await input.deliverActionResult(result) == .closed)
    #expect(
        await input.deliverActivityEvent(ActivityEvent(activityID: UUID(), owner: owner, state: .failed, sequence: 1))
            == .closed)
    #expect(await replacement.results().isEmpty)
    #expect(await replacement.activities.isEmpty)
    let current = ExecutionOwner(
        agent: .assistant, incarnation: try await manager.identity(.assistant), sessionID: session)
    #expect(
        await input.deliverActivityEvent(
            ActivityEvent(activityID: UUID(), owner: current, state: .started, sequence: 1)) == .accepted)
}

@Test(.timeLimit(.minutes(1))) func terminalSlotIsReservedBeforeActionAdmissionAndDoesNotHoldLane() async throws {
    let deliveryStarted = LifecycleGate()
    let releaseDelivery = LifecycleGate()
    let counter = LifecycleCounter()
    let registry = try ActionRegistry(definitions: [
        ActionDefinition(path: lifecyclePath, displayName: "测试动作", kind: .state, completion: "State committed.") { _ in
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
    try await scheduler.finish(inputID: first.envelope.inputID)
    await deliveryStarted.wait()
    await #expect(throws: ActionSchedulingError.resultCapacityExceeded) {
        try await scheduler.enqueue(invocation: lifecycleInvocation(owner: owner))
    }
    let noFeedback = try lifecycleInvocation(owner: owner, feedback: .none)
    try await scheduler.enqueue(invocation: noFeedback)
    try await scheduler.finish(inputID: noFeedback.envelope.inputID)
    #expect(await counter.value == 2)
    await releaseDelivery.release()
    await scheduler.finishResultDelivery()
}

@Test func activityStartReturnsAHandleWithoutWaitingForActivityTermination() async throws {
    let activityID = UUID()
    let registry = try ActionRegistry(definitions: [
        ActionDefinition(
            path: lifecyclePath, displayName: "测试动作", kind: .activityStart, completion: "Capture active.",
            completing: { _ in
                .activityStarted(activityID)
            })
    ])
    let scheduler = ChannelScheduler(registry: registry) { _ in .accepted }
    let invocation = try lifecycleInvocation(owner: lifecycleOwner())
    try await scheduler.enqueue(invocation: invocation)
    try await scheduler.finish(inputID: invocation.envelope.inputID)
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
    #expect(await resources.snapshot()[armResource] == .available)
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
    #expect(await resources.snapshot()[secondResource] == .available)
    #expect(await revocations.value == 2)  // Initial gate and subsequent owner revocation.
    await #expect(throws: ResourceError.staleLease) { try await resources.release(first, owner: owner) }
    #expect(await resources.snapshot()[armResource] == .leased(replacement.id))
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
        ActionDefinition(
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
    #expect(await resources.snapshot()[armResource] == .leased(replacement.id))
    #expect(await scheduler.diagnosticSnapshot().records.filter { $0.phase == .cancelled }.count == 2)
    await #expect(throws: ResourceError.staleLease) {
        try await scheduler.enqueue(invocation: invocation)
    }
    try await resources.release(replacement, owner: next)
}

@Test(.timeLimit(.minutes(1))) func cleanupTimeoutKeepsGateClosedUntilExplicitRecovery() async throws {
    let releaseStop = LifecycleGate()
    let resources = try ResourceCoordinator(
        definitions: [
            ResourceDefinition(id: armResource, allowedOwners: [.assistant]) { await releaseStop.wait() }
        ], cleanupDeadline: .milliseconds(20))
    await #expect(throws: ResourceError.cleanupTimedOut) {
        try await resources.acquire(resources: [armResource], owner: lifecycleOwner(), duration: .seconds(10)) { _ in }
    }
    #expect(await resources.snapshot()[armResource] == .faulted)
    await #expect(throws: ResourceError.busy) { try await resources.recover([armResource]) }
    await releaseStop.release()
    for _ in 0..<10000 {
        if await resources.activeCleanupCount() == 0 { break }
        await Task.yield()
    }
    #expect(await resources.activeCleanupCount() == 0)
    #expect(await resources.snapshot()[armResource] == .faulted)
    try await resources.recover([armResource])
    #expect(await resources.snapshot()[armResource] == .available)
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
        if await resources.snapshot()[armResource] == .available { break }
        await Task.yield()
    }
    #expect(await resources.snapshot()[armResource] == .available)
    await #expect(throws: ResourceError.staleLease) {
        try await resources.renew(lease, owner: owner, duration: .seconds(1))
    }
}

@Test func protectedToolCannotBypassResourceOwnership() async throws {
    let resources = try lifecycleResources()
    let original = lifecycleOwner()
    let lease = try await resources.acquire(resources: [armResource], owner: original, duration: .seconds(10)) { _ in }
    let manager = AgentManager()
    let capabilities = try CapabilityRegistry(tools: [ToolRegistration(alias: "move", path: "move")])
    let agent = try ReceiptAgent(id: otherAgent, capabilities: capabilities)
    let session = UUID()
    try await manager.register(agent, sessionID: session)
    try await manager.start(otherAgent)
    let input = InputGateway(manager: manager)
    let tools = ToolRegistry()
    let count = LifecycleCounter()
    try await tools.registerCompletion("move", resources: [ToolResource(rawValue: armResource.rawValue)]) { _, _ in
        await count.increment()
    }
    let output = OutputGateway(
        manager: manager, requests: input, tools: tools,
        actions: ChannelScheduler(registry: ActionRegistry(), resources: resources), sink: { _ in })
    await #expect(throws: ResourceError.staleLease) {
        try await output.dispatch(
            OutputEnvelope(
                source: otherAgent, input: AgentInput(sessionID: session, payload: .event("test")),
                output: .toolCall(ToolCall(toolPath: "move", arguments: [:]))))
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
        manager: manager, requests: InputGateway(manager: manager), tools: ToolRegistry(),
        actions: ChannelScheduler(registry: ActionRegistry(), resources: resources), sink: { _ in })
    let control = try await output.resourceControl(for: .assistant, sessionID: session)
    let lease = try await control.acquire([armResource], .seconds(10))
    try await manager.remove(.assistant)
    await #expect(throws: CommunicationError.staleIncarnation) { try await control.renew(lease, .seconds(10)) }
    // AgentManager stop hooks automatically clean the lease; stale release cannot affect later owners.
    await #expect(throws: ResourceError.staleLease) { try await control.release(lease) }
    #expect(await resources.snapshot()[armResource] == .available)
}

@Test(.timeLimit(.minutes(1))) func sessionCloseStopsResourceBeforeJoiningCancelledHandler() async throws {
    let device = RevocationDevice()
    let resources = try lifecycleResources { await device.stop() }
    let registry = try ActionRegistry(definitions: [
        ActionDefinition(
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
        manager: manager, requests: InputGateway(manager: manager), tools: ToolRegistry(),
        actions: scheduler, sink: { _ in })
    let owner = lifecycleOwner()
    try await scheduler.enqueue(invocation: lifecycleInvocation(owner: owner, feedback: .none))
    await device.running.wait()
    await output.cancel(sessionID: owner.sessionID)
    #expect(await resources.snapshot()[armResource] == .available)
    #expect(await scheduler.diagnosticSnapshot().records.last?.phase == .cancelled)
}

@Test func activityCompletionMustMatchItsRegisteredKind() async throws {
    let registry = try ActionRegistry(definitions: [
        ActionDefinition(
            path: lifecyclePath, displayName: "测试动作", kind: .finite, completion: "Finite operation.",
            completing: { _ in
                .activityStarted(UUID())
            })
    ])
    await #expect(throws: ActionExecutionError.invalidCompletion) {
        try await ActionExecutor(registry: registry).execute(lifecycleInvocation(owner: lifecycleOwner()))
    }
}
