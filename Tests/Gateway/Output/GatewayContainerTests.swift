import Actions
import AgentCore
import AppLifecycle
import AppStorage
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Testing

@testable import Agents
@testable import Gateway

private actor GatewayTestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
private actor GatewayCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
private let gatewayPath = ActionIdentifier(domain: "Fixture", module: "Execution", function: "perform")
private enum GatewayTestError: Error { case cleanup }
private struct GatewayFixtureModule: CapabilityModule { let definitions: [ActionFunction] }

private actor ActionFeedbackReceiver: Agent {
    nonisolated let descriptor = AgentDescriptor(
        category: .cognition, id: .assistant, name: "Action feedback fixture", inputs: [.executionFeedback], outputs: []
    )
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    private(set) var attempts = 0
    private(set) var inputs: [AgentInput] = []
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}
    func status() -> AgentStatus { .init(lifecycle: .running, queuedInputs: 0, processedInputs: inputs.count) }
    func receive(_ input: AgentInput) throws {
        guard case .executionFeedback(.actionFinished) = input.payload else { return }
        attempts += 1
        guard attempts > 1 else { throw CommunicationError.capacityExceeded }
        inputs.append(input)
    }
}

@MainActor private struct GatewayHarness {
    let actions: ActionsContainer
    let engine: ActionExecutionCoordinator
    let root: GatewayContainer
    let ports: GatewayCapabilities
    let execution: ActionExecutionTransport
    init(resources: [ResourceDefinition] = [], handler: @escaping ActionHandler = { _ in }) async throws {
        let actions = ActionsContainer()
        try actions.configure(
            BehaviorAssembly(capabilityModules: [
                GatewayFixtureModule(definitions: [
                    .init(
                        path: gatewayPath, displayName: "Fixture", kind: .finite, completion: "Joined.",
                        handler: handler)
                ])
            ]))
        let engine = try actions.configureExecution(resources: resources)
        try actions.start()
        let root = GatewayContainer()
        let ports = try root.configure()
        self.ports = ports
        self.execution = try await ActionExecutionTransport.connect(ports: ports, engine: engine)
        _ = try await ports.signals.register(address: "producer", incarnation: "generation") { _ in }
        self.actions = actions
        self.engine = engine
        self.root = root
    }
    func stop() async throws {
        try await root.stop()
        try await actions.stop()
    }
}
private func gatewayJob(id: String = UUID().uuidString) throws -> ScheduledAction {
    let context = ActionExecutionContext(source: "producer", sessionID: "session", inputID: id)
    return try ScheduledAction(
        envelope: .init(
            source: context.source, sessionID: context.sessionID,
            inputID: id, schedulingScope: .input(id), context: context), call: .init(actionPath: gatewayPath),
        channel: "main",
        owner: .init(endpoint: "producer", incarnation: "generation", sessionID: "session"))
}
private func gatewaySignal(id: String = UUID().uuidString, cleanup: Bool = false) -> SignalEnvelope {
    .init(
        id: id, sessionID: "session", contract: "fixture.data", channel: cleanup ? "fixture.cleanup" : nil,
        payloadBytes: 4, cleanup: cleanup)
}

@Test(.actionCatalog) @MainActor func gatewayRequiresConfigurationAndCannotRestartAfterStop() async throws {
    let root = GatewayContainer()
    await #expect(throws: GatewayFailure.self) { try await root.start() }
    #expect(throws: GatewayFailure.self) { _ = try root.capabilities }
    try await root.stop()
    await #expect(throws: GatewayFailure.self) { try await root.start() }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func actionTerminalReturnsThroughGatewayBeforeAgentsAdaptation() async throws {
    let executions = GatewayCounter()
    let actions = ActionsContainer()
    let path = ActionIdentifier(domain: "System", module: "Device", function: "readStatus")
    try actions.configure(
        BehaviorAssembly(capabilityModules: [
            GatewayFixtureModule(definitions: [
                .init(
                    path: path, displayName: "Fixture", kind: .finite, completion: "Joined.",
                    handler: { invocation in
                        await executions.increment()
                        if invocation.call.parameters["fail"] == "true" { throw GatewayTestError.cleanup }
                    })
            ])
        ]))
    let engine = try actions.configureExecution(resources: [])
    try actions.start()
    let root = GatewayContainer()
    let ports = try root.configure()
    let assembly = AgentGatewayAssembly(
        signals: ports.signals, admission: ports.admission, configuration: .init(catalog: try actions.catalog()))
    let agents = try await assembly.bind(ports: ports, observations: root.observations, engine: engine)
    let agent = ActionFeedbackReceiver()
    let session = UUID().uuidString
    try await agents.manager.register(agent, sessionID: session)
    _ = try await agents.output.consumer(for: agent)
    try await root.start()

    let incarnation = try await agents.manager.identity(.assistant)
    let owner = ExecutionOwner(agent: .assistant, incarnation: incarnation, sessionID: session)
    let context = ActionExecutionContext(source: owner.endpoint, sessionID: session, inputID: UUID().uuidString)
    let round = UUID().uuidString
    let call = UUID().uuidString
    let job = try ScheduledAction(
        envelope: .init(
            source: owner.endpoint, sessionID: session, inputID: context.inputID, schedulingScope: .round(round),
            callID: call, context: context),
        call: .init(actionPath: path), channel: "main", owner: owner, feedback: .terminal)
    _ = try await agents.execution.roundBoundary(.init(roundID: round, scope: .start), lane: .action, owner: owner)
    let executionID = try await agents.execution.enqueue(invocation: job)
    let settlement = try #require(
        try await agents.execution.roundBoundary(.init(roundID: round, scope: .end), lane: .action, owner: owner))
    try await settlement.wait()

    #expect(await executions.count == 1)
    #expect(await agent.attempts == 2)
    let inputs = await agent.inputs
    try #require(inputs.count == 1)
    if case .executionFeedback(.actionFinished(let result)) = inputs[0].payload {
        #expect(result.executionID == executionID && result.roundID == round && result.callID == call)
        #expect(result.owner == owner && result.status == .succeeded)
        #expect(inputs[0].metadata.parentID == context.inputID && inputs[0].metadata.hops == 1)
    } else {
        Issue.record("Expected an adapted Action terminal")
    }
    let tool = ToolRequest(id: UUID().uuidString, toolPath: path.description)
    let failingTool = ToolRequest(id: UUID().uuidString, toolPath: path.description, arguments: ["fail": "true"])
    let toolInvocation = FunctionInvocation(tool: tool, context: context, roundID: round)
    _ = try await agents.execution.roundBoundary(.init(roundID: round, scope: .start), lane: .tool, owner: owner)
    let receipt = try await agents.execution.execute(toolInvocation, owner: owner)
    #expect(receipt == .completed)
    await #expect(throws: GatewayTestError.cleanup) {
        try await agents.execution.execute(.init(tool: failingTool, context: context, roundID: round), owner: owner)
    }
    let toolSettlement = try #require(
        try await agents.execution.roundBoundary(.init(roundID: round, scope: .end), lane: .tool, owner: owner))
    try await toolSettlement.wait()
    #expect(await executions.count == 3)
    #expect(await agent.inputs.count == 1)

    let raw = try #require(await engine.scheduler.resultSnapshot().first?.result)
    let agentEndpoint = try await ports.signals.endpoint(address: owner.endpoint, incarnation: incarnation)
    let actionsEndpoint = try await ports.signals.endpoint(address: "actions.execution")
    let resultEndpoint = try await ports.signals.endpoint(address: "agents.execution.results")
    let invalidResults: [(SignalEndpoint, String, CommunicationError)] = [
        (agentEndpoint, session, .unauthorized),
        (actionsEndpoint, "other-session", .invalidPayload),
    ]
    for (source, envelopeSession, error) in invalidResults {
        await #expect(throws: error) {
            try await ports.signals.send(
                source: source, target: resultEndpoint,
                envelope: .init(
                    id: executionID, sessionID: envelopeSession, contract: CallResultSignal.contract,
                    channel: CallResultSignal.channel, payloadBytes: 0),
                payload: CallResultSignal.action(raw))
        }
    }
    #expect(await agent.attempts == 2)
    await agents.output.shutdown()
    await agents.manager.stopAll()
    try await root.stop()
    try await actions.stop()
}

@Test(.actionCatalog) @MainActor func gatewayRoundBoundariesArePerCallLaneAndRejectLateActions() async throws {
    let entered = GatewayTestGate()
    let release = GatewayTestGate()
    let harness = try await GatewayHarness { _ in
        await entered.release()
        await release.wait()
    }
    try await harness.root.start()
    let round = UUID().uuidString
    let owner = ExecutionOwner(endpoint: "producer", incarnation: "generation", sessionID: "session")
    let context = ActionExecutionContext(source: owner.endpoint, sessionID: owner.sessionID, inputID: "input")
    let action = try ScheduledAction(
        envelope: .init(
            source: owner.endpoint, sessionID: owner.sessionID, inputID: context.inputID,
            schedulingScope: .round(round), callID: "call", context: context),
        call: .init(actionPath: gatewayPath), channel: "main", owner: owner)
    let execution = harness.execution
    await #expect(throws: ActionSchedulingError.invalidSchedule) { _ = try await execution.enqueue(invocation: action) }
    _ = try await execution.roundBoundary(.init(roundID: round, scope: .start), lane: .action, owner: owner)
    _ = try await execution.roundBoundary(.init(roundID: round, scope: .start), lane: .tool, owner: owner)
    _ = try await execution.enqueue(invocation: action)
    await entered.wait()
    do {
        let sealedAction = try #require(
            try await execution.roundBoundary(.init(roundID: round, scope: .end), lane: .action, owner: owner))
        let sealedTool = try #require(
            try await execution.roundBoundary(.init(roundID: round, scope: .end), lane: .tool, owner: owner))
        try await sealedTool.wait()
        await #expect(throws: ActionSchedulingError.invalidSchedule) {
            _ = try await execution.enqueue(invocation: action)
        }
        await release.release()
        try await sealedAction.wait()
        let repeatedEnd = try #require(
            try await execution.roundBoundary(.init(roundID: round, scope: .end), lane: .action, owner: owner))
        try await repeatedEnd.wait()
        try await harness.stop()
    } catch {
        await release.release()
        try await harness.stop()
        throw error
    }
}

@Test(.actionCatalog) @MainActor func gatewayAcceptsOnlyOneConfigurationAndCachedPortsClose() async throws {
    let harness = try await GatewayHarness()
    #expect(throws: GatewayFailure.self) {
        try harness.root.configure()
    }
    await #expect(throws: GatewayContainerError.self) {
        try await harness.execution.enqueue(invocation: gatewayJob())
    }
    async let one: Void = harness.root.start()
    async let two: Void = harness.root.start()
    _ = try await (one, two)
    async let closeOne: Void = harness.root.stop()
    async let closeTwo: Void = harness.root.stop()
    _ = try await (closeOne, closeTwo)
    #expect(harness.root.state == .stopped)
    await #expect(throws: Error.self) { try await harness.execution.enqueue(invocation: gatewayJob()) }
    try await harness.actions.stop()
}

@Test(.actionCatalog) @MainActor func toolCallTransportPreservesLargeResultsAndChecksTheBoundOwner() async throws {
    let path = ActionIdentifier(domain: "Artifacts", module: "Fixture", function: "read")
    let size = 4 * 1024 * 1024 + 1
    let calls = GatewayCounter()
    let actions = ActionsContainer()
    try actions.configure(
        BehaviorAssembly(capabilityModules: [
            GatewayFixtureModule(definitions: [
                .init(
                    path: path, displayName: "Read fixture", kind: .finite, completion: "Read complete.",
                    completing: { invocation in
                        await calls.increment()
                        let deadline = ContinuousClock.now + .seconds(3)
                        while await calls.count < 2 {
                            guard .now < deadline else { throw GatewayTestError.cleanup }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        let prefix = invocation.call.parameters["marker"] ?? ""
                        return .value(prefix + String(repeating: "a", count: size))
                    })
            ])
        ]))
    let engine = try actions.configureExecution(resources: [])
    try actions.start()
    let root = GatewayContainer()
    let ports = try root.configure()
    let execution = try await ActionExecutionTransport.connect(ports: ports, engine: engine)
    let owner = ExecutionOwner(endpoint: "writer", incarnation: "one", sessionID: "session")
    _ = try await ports.signals.register(address: owner.endpoint, incarnation: owner.incarnation) { _ in }
    try await root.start()
    let tool = ToolRequest(id: UUID().uuidString, toolPath: path.description)
    let foreign = FunctionInvocation(
        tool: tool, context: .init(source: owner.endpoint, sessionID: "other", inputID: "input"))
    await #expect(throws: ActionExecutionError.invalidInvocation) { try await execution.execute(foreign, owner: owner) }
    #expect(await calls.count == 0)
    let context = ActionExecutionContext(source: owner.endpoint, sessionID: owner.sessionID, inputID: "input")
    let firstRound = UUID().uuidString
    let secondRound = UUID().uuidString
    for round in [firstRound, secondRound] {
        _ = try await execution.roundBoundary(.init(roundID: round, scope: .start), lane: .tool, owner: owner)
    }
    let firstTool = ToolRequest(id: tool.id, toolPath: tool.toolPath, arguments: ["marker": "1"])
    let secondTool = ToolRequest(id: tool.id, toolPath: tool.toolPath, arguments: ["marker": "2"])
    async let first = execution.execute(.init(tool: firstTool, context: context, roundID: firstRound), owner: owner)
    async let second = execution.execute(.init(tool: secondTool, context: context, roundID: secondRound), owner: owner)
    if case (.value(let firstValue), .value(let secondValue)) = try await (first, second) {
        #expect(firstValue.utf8.count == size + 1 && firstValue.hasPrefix("1"))
        #expect(secondValue.utf8.count == size + 1 && secondValue.hasPrefix("2"))
    } else {
        Issue.record("Expected one complete result for each Tool round")
    }
    #expect(await calls.count == 2)
    try await root.stop()
    try await actions.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func visionSessionCallsPresentationToolsAfterCameraRequestReturns() async throws {
    let posePath = ActionIdentifier(domain: "UI", module: "Pose", function: "showPose")
    let gazePath = ActionIdentifier(domain: "UI", module: "Gaze", function: "moveEyes")
    let poseCalls = GatewayCounter()
    let gazeCalls = GatewayCounter()
    let actions = ActionsContainer()
    try actions.configure(
        BehaviorAssembly(capabilityModules: [
            GatewayFixtureModule(definitions: [
                .init(
                    path: posePath, displayName: "Pose fixture", kind: .finite, completion: "Presented.",
                    handler: { _ in await poseCalls.increment() }),
                .init(
                    path: gazePath, displayName: "Gaze fixture", kind: .finite, completion: "Presented.",
                    handler: { _ in await gazeCalls.increment() }),
            ])
        ]))
    let engine = try actions.configureExecution(resources: [])
    try actions.start()
    let root = GatewayContainer()
    let ports = try root.configure()
    let execution = try await ActionExecutionTransport.connect(ports: ports, engine: engine)
    let signals = ports.signals
    let visionPerception = try await signals.register(address: AgentID.visionPerception.rawValue, incarnation: "one") {
        _ in
    }
    let actionsEndpoint = try await signals.endpoint(address: "actions.execution")
    let owner = ExecutionOwner(endpoint: AgentID.visionPerception.rawValue, incarnation: "one", sessionID: "vision")
    _ = try await signals.register(address: owner.endpoint, incarnation: owner.incarnation) { _ in }
    let context = ActionExecutionContext(source: owner.endpoint, sessionID: owner.sessionID, inputID: "frame")
    let pose = FunctionInvocation(
        tool: .init(id: "pose", toolPath: posePath.description), context: context)
    let gaze = FunctionInvocation(
        tool: .init(id: "gaze", toolPath: gazePath.description), context: context)
    let vision = VisionCaptureSessionHost()
    let frames = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let presented = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let open = try SignalRequestProtocol<Bool, Task<Void, any Error>>(
        id: "fixture.camera.open.v1", maximumRequestBytes: 1, maximumReplyBytes: nil, requestSize: { _ in 1 })
    try await signals.registerRequest(open, endpoint: actionsEndpoint) { _ in
        await #expect(throws: SignalTransportError.cyclicRequest) {
            _ = try await execution.execute(pose, owner: owner)
        }
        return Task {
            defer { presented.continuation.finish() }
            try await vision.run {
                for await _ in frames.stream {
                    let poseResult = try await execution.execute(pose, owner: owner)
                    let gazeResult = try await execution.execute(gaze, owner: owner)
                    #expect(poseResult == .completed)
                    #expect(gazeResult == .completed)
                    presented.continuation.yield(true)
                }
                try Task.checkCancellation()
            }
        }
    }
    try await root.start()
    let session = try await signals.request(
        source: visionPerception, target: actionsEndpoint, using: open, request: true)
    frames.continuation.yield(())
    var receipts = presented.stream.makeAsyncIterator()
    #expect(await receipts.next() == true)
    try await vision.suspend()
    await #expect(throws: CancellationError.self) { try await session.value }
    frames.continuation.finish()
    try await vision.stop()
    try await root.stop()
    try await actions.stop()
    #expect(await poseCalls.count == 1)
    #expect(await gazeCalls.count == 1)
}

@Test(.actionCatalog) @MainActor func failedExecutionBindingLeavesIndependentTransportAvailable() async throws {
    let harness = try await GatewayHarness()
    let root = GatewayContainer()
    let ports = try root.configure()
    await #expect(throws: ActionSchedulingError.signalsAlreadyBound) {
        try await ActionExecutionTransport.connect(ports: ports, engine: harness.engine)
    }
    await #expect(throws: SignalTransportError.duplicateEndpoint) {
        try await ActionExecutionTransport.connect(ports: harness.ports, engine: harness.engine)
    }
    try await harness.root.start()
    _ = try await harness.execution.enqueue(invocation: gatewayJob())
    #expect(root.state == .configured)
    try await root.start()
    let endpoint = try await ports.signals.register(
        address: "independent", incarnation: "one", sendChannels: ["fixture.data", "fixture.cleanup"]
    ) { _ in }
    try await ports.signals.send(source: endpoint, target: endpoint, envelope: gatewaySignal(), payload: 1)
    try await root.stop()
    try await harness.stop()
}

@Test(.actionCatalog) @MainActor func gatewaySignalEndpointsAreGenericAndRejectStaleIncarnations() async throws {
    let harness = try await GatewayHarness()
    try await harness.root.start()
    let count = GatewayCounter()
    let source = try await harness.ports.signals.register(address: "source", incarnation: "first") { _ in }
    let target = try await harness.ports.signals.register(
        address: "target", incarnation: "first", sendChannels: ["fixture.data", "fixture.cleanup"]
    ) { signal in
        #expect((signal.payload as? String) == "data")
        await count.increment()
    }
    try await harness.ports.signals.send(source: source, target: target, envelope: gatewaySignal(), payload: "data")
    _ = try await harness.ports.signals.register(address: "source", incarnation: "replacement") { _ in }
    await #expect(throws: SignalTransportError.staleEndpoint) {
        try await harness.ports.signals.send(source: source, target: target, envelope: gatewaySignal(), payload: "data")
    }
    #expect(await count.count == 1)
    try await harness.stop()
}

@Test(.actionCatalog) @MainActor func gatewayValidatesEnvelopeWithoutInterpretingBusinessPayload() async throws {
    let harness = try await GatewayHarness()
    try await harness.root.start()
    let source = try await harness.ports.signals.register(address: "source", incarnation: "one") { _ in }
    let target = try await harness.ports.signals.register(
        address: "target", incarnation: "one", sendChannels: ["fixture.data", "fixture.cleanup"]
    ) { signal in
        #expect(signal.payload as? Int == 42)
    }
    try await harness.ports.signals.send(source: source, target: target, envelope: gatewaySignal(), payload: 42)
    await #expect(throws: SignalTransportError.invalidEnvelope) {
        try await harness.ports.signals.send(
            source: source, target: target,
            envelope: .init(id: "invalid", sessionID: "session", contract: "fixture.data", version: 2, payloadBytes: 4),
            payload: 42)
    }
    await #expect(throws: SignalTransportError.expired) {
        try await harness.ports.signals.send(
            source: source, target: target,
            envelope: .init(
                id: "expired", sessionID: "session", contract: "fixture.data", payloadBytes: 4,
                expiresAt: .now.advanced(by: .seconds(-1))), payload: 42)
    }
    try await harness.stop()
}

@Test(.actionCatalog) @MainActor func gatewayPauseFencesPortsAndResumeRetainsEndpoints() async throws {
    let count = GatewayCounter()
    let harness = try await GatewayHarness(handler: { _ in await count.increment() })
    try await harness.root.start()
    let endpoint = try await harness.ports.signals.register(
        address: "endpoint", incarnation: "one", sendChannels: ["fixture.data", "fixture.cleanup"]
    ) { _ in }
    harness.root.invalidate()
    await #expect(throws: GatewayContainerError.self) {
        try await harness.ports.signals.send(
            source: endpoint, target: endpoint, envelope: gatewaySignal(), payload: "data")
    }
    await #expect(throws: GatewayContainerError.self) {
        try await harness.execution.enqueue(invocation: gatewayJob())
    }
    try await harness.root.setForeground(true)
    try await harness.ports.signals.send(source: endpoint, target: endpoint, envelope: gatewaySignal(), payload: "data")
    let job = try gatewayJob()
    try await harness.execution.enqueue(invocation: job)
    try await harness.execution.finish(scope: job.envelope.schedulingScope, source: job.envelope.source)
    #expect(await count.count == 1)
    try await harness.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor func gatewayStopJoinsAdmittedSignalReceivers() async throws {
    let started = GatewayTestGate()
    let cleaning = GatewayTestGate()
    let release = GatewayTestGate()
    let harness = try await GatewayHarness()
    try await harness.root.start()
    let endpoint = try await harness.ports.signals.register(
        address: "endpoint", incarnation: "one", sendChannels: ["fixture.data", "fixture.cleanup"]
    ) { _ in
        await started.release()
        do { try await Task.sleep(for: .seconds(30)) } catch {
            await cleaning.release()
            await release.wait()
            throw error
        }
    }
    let send = Task {
        try await harness.ports.signals.send(
            source: endpoint, target: endpoint, envelope: gatewaySignal(), payload: "data")
    }
    await started.wait()
    let stopping = Task { try await harness.root.stop() }
    await cleaning.wait()
    #expect(harness.root.state == .stopping)
    await release.release()
    try await stopping.value
    _ = await send.result
    try await harness.actions.stop()
}

@Test(.actionCatalog) @MainActor func gatewayObservationScopesAreBoundedIsolatedAndRootOwned() async throws {
    let harness = try await GatewayHarness()
    try await harness.root.start()
    let first = try harness.root.observations.open()
    #expect(throws: Error.self) { try harness.root.observations.open() }
    #expect(first.capabilities.signals !== harness.ports.signals)
    let endpoint = try await first.capabilities.signals.register(
        address: "isolated", incarnation: "one", sendChannels: ["fixture.data", "fixture.cleanup"]
    ) { _ in }
    harness.root.invalidate()
    await #expect(throws: GatewayContainerError.self) {
        try await first.capabilities.signals.send(
            source: endpoint, target: endpoint, envelope: gatewaySignal(), payload: "data")
    }
    try await harness.root.setForeground(true)
    try await harness.root.observations.close(first)
    await #expect(throws: SignalTransportError.closed) {
        try await first.capabilities.signals.send(
            source: endpoint, target: endpoint, envelope: gatewaySignal(), payload: "data")
    }
    let next = try harness.root.observations.open()
    try await harness.root.stop()
    await #expect(throws: SignalTransportError.closed) {
        _ = try await next.capabilities.signals.register(address: "late", incarnation: "one") { _ in }
    }
    try await harness.actions.stop()
}

@Test(.actionCatalog) @MainActor func gatewayCancelledStartupClosesConfiguredPorts() async throws {
    let harness = try await GatewayHarness()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await harness.root.start()
    }
    await #expect(throws: GatewayFailure.self) { try await task.value }
    #expect(harness.root.state == .stopped && !harness.root.isAvailable)
    try await harness.actions.stop()
}

@Test(.actionCatalog) @MainActor func gatewayExecutionRejectsUnboundAndStaleEndpointsBeforeEffects() async throws {
    let count = GatewayCounter()
    let harness = try await GatewayHarness { _ in await count.increment() }
    try await harness.root.start()
    await harness.ports.signals.unregister(address: "producer", incarnation: "generation")
    await #expect(throws: SignalTransportError.staleEndpoint) {
        try await harness.execution.enqueue(invocation: gatewayJob())
    }
    _ = try await harness.ports.signals.register(address: "producer", incarnation: "replacement") { _ in }
    await #expect(throws: SignalTransportError.staleEndpoint) {
        try await harness.execution.enqueue(invocation: gatewayJob())
    }
    #expect(await count.count == 0)
    try await harness.stop()
}

@Test(.actionCatalog) @MainActor func gatewaySignalCleanupRetainsCapacityUnderOrdinaryLoad() async throws {
    let transport = SignalTransport()
    let entered = GatewayTestGate()
    let release = GatewayTestGate()
    let endpoint = try await transport.register(
        address: "receiver", incarnation: "one", sendChannels: ["fixture.data", "fixture.cleanup"]
    ) { signal in
        if !signal.envelope.cleanup {
            await entered.release()
            await release.wait()
        }
    }
    let ordinary = Task {
        try await transport.send(
            source: nil, target: endpoint,
            envelope: .init(id: "large", sessionID: "session", contract: "fixture.data", payloadBytes: 7936 * 1024),
            payload: 1)
    }
    await entered.wait()
    await #expect(throws: SignalTransportError.capacityExceeded) {
        try await transport.send(source: nil, target: endpoint, envelope: gatewaySignal(), payload: 1)
    }
    try await transport.send(source: nil, target: endpoint, envelope: gatewaySignal(cleanup: true), payload: 1)
    await #expect(throws: SignalTransportError.capacityExceeded) {
        try await transport.send(
            source: nil, target: endpoint,
            envelope: .init(
                id: "oversized", sessionID: "session", contract: "fixture.data",
                payloadBytes: 256 * 1024 + 1, cleanup: true), payload: 1)
    }
    await release.release()
    try await ordinary.value
    await transport.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func gatewaySendAndRequestRunConcurrentlyOnTheSameChannel() async throws {
    let transport = SignalTransport()
    let entered = GatewayTestGate()
    let release = GatewayTestGate()
    let acknowledged = GatewayCounter()
    let source = try await transport.register(address: "producer", incarnation: "one") { _ in }
    let target = try await transport.register(
        address: "receiver", incarnation: "one", sendChannels: ["fixture.data", "fixture.cleanup"]
    ) { signal in
        if signal.envelope.id == "first" {
            await entered.release()
            await release.wait()
        }
        await acknowledged.increment()
    }
    let request = try integerSignalProtocol(timeout: .seconds(10))
    let channel = "fixture.requests"
    try await transport.registerRequest(request, endpoint: target, channel: channel) { $0 + 1 }
    let first = Task {
        try await transport.send(
            source: source, target: target,
            envelope: .init(
                id: "first", sessionID: "session", contract: "fixture.send.v1", channel: channel, payloadBytes: 1),
            payload: 1)
    }
    await entered.wait()
    do {
        let reply = try await transport.request(
            source: source, target: target, using: request, request: 2,
            envelope: .init(
                id: "typed", sessionID: "session", contract: request.id, channel: channel, payloadBytes: 8))
        #expect(reply == 3)
        try await transport.send(
            source: source, target: target,
            envelope: .init(
                id: "second", sessionID: "session", contract: "fixture.send.v1", channel: channel, payloadBytes: 1),
            payload: 3, timeout: .seconds(10))
        #expect(await acknowledged.count == 1)
        await release.release()
        try await first.value
        #expect(await acknowledged.count == 2)
        await transport.shutdown()
    } catch {
        await release.release()
        first.cancel()
        await transport.shutdown()
        throw error
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func gatewaySendTimeoutCancelsReceiverAndReleasesCapacity() async throws {
    let transport = SignalTransport()
    let stopped = GatewayCounter()
    let target = try await transport.register(
        address: "receiver", incarnation: "one", sendChannels: ["fixture.timeout.v1"]
    ) { signal in
        #expect(signal.envelope.expiresAt != nil)
        do {
            try await Task.sleep(for: .seconds(5))
        } catch is CancellationError {
            await stopped.increment()
            throw CancellationError()
        }
    }
    await #expect(throws: SignalTransportError.expired) {
        try await transport.send(
            source: nil, target: target,
            envelope: .init(id: "send", sessionID: "session", contract: "fixture.timeout.v1", payloadBytes: 1),
            payload: 1, timeout: .seconds(2))
    }
    #expect(await stopped.count == 1)
    #expect(try await transport.stateSnapshot().runtime["active"] == .count(0))
    await transport.shutdown()
}

@Test(.actionCatalog) @MainActor func gatewaySignalReplacementRejectsOldCompletionAndPreservesFailure() async throws {
    for replaceSource in [true, false] {
        for fails in [true, false] {
            let transport = SignalTransport()
            let entered = GatewayTestGate()
            let release = GatewayTestGate()
            let source = try await transport.register(address: "source", incarnation: "one") { _ in }
            let target = try await transport.register(
                address: "target", incarnation: "one", sendChannels: ["fixture.data", "fixture.cleanup"]
            ) { _ in
                await entered.release()
                await release.wait()
                if fails { throw GatewayTestError.cleanup }
            }
            let pending = Task {
                try await transport.send(source: source, target: target, envelope: gatewaySignal(), payload: 1)
            }
            await entered.wait()
            _ = try await transport.register(address: replaceSource ? "source" : "target", incarnation: "two") { _ in }
            await release.release()
            if fails {
                await #expect(throws: GatewayTestError.cleanup) { try await pending.value }
            } else {
                await #expect(throws: CancellationError.self) { try await pending.value }
            }
            await transport.shutdown()
        }
    }
}

private func integerSignalProtocol(id: String = "fixture.request.v1", timeout: Duration = .seconds(2)) throws
    -> SignalRequestProtocol<Int, Int>
{
    try .init(
        id: id, maximumRequestBytes: 8, maximumReplyBytes: 8, timeout: timeout,
        requestSize: { _ in 8 }, replySize: { _ in 8 })
}

@Test(.actionCatalog) @MainActor func gatewayRequestRepliesWithoutSourceInboxAndRejectsUnknownProtocol() async throws {
    let transport = SignalTransport()
    let calls = GatewayCounter()
    let source = try await transport.register(address: "caller", incarnation: "one") { _ in
        Issue.record("A direct reply must never enter the caller inbox")
    }
    let target = try await transport.register(address: "receiver", incarnation: "one") { _ in
        Issue.record("A typed request must enter its handler")
    }
    let descriptor = try integerSignalProtocol()
    try await transport.registerRequest(descriptor, endpoint: target) { value in
        await calls.increment()
        return value + 1
    }
    #expect(try await transport.request(source: source, target: target, using: descriptor, request: 41) == 42)
    await #expect(throws: SignalTransportError.unsupportedProtocol) {
        try await transport.request(
            source: source, target: target, using: integerSignalProtocol(id: "fixture.other.v1"), request: 1)
    }
    #expect(await calls.count == 1)
    await transport.shutdown()
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func gatewayRequestTimeoutJoinsHandlerAndReleasesBudget() async throws {
        let transport = SignalTransport()
        let source = try await transport.register(address: "caller", incarnation: "one") { _ in }
        let target = try await transport.register(address: "receiver", incarnation: "one") { _ in }
        let joined = GatewayCounter()
        let descriptor = try integerSignalProtocol(timeout: .milliseconds(20))
        try await transport.registerRequest(descriptor, endpoint: target) { value in
            do { try await Task.sleep(for: .seconds(10)) } catch {
                await joined.increment()
                throw error
            }
            return value
        }
        await #expect(throws: SignalTransportError.expired) {
            try await transport.request(source: source, target: target, using: descriptor, request: 1)
        }
        #expect(await joined.count == 1)
        let snapshot = try await transport.stateSnapshot()
        #expect(snapshot.runtime["active"] == .count(0))
        #expect(snapshot.runtime["bytes"] == .count(0))
        await transport.shutdown()
    }

}

@Test(.actionCatalog) @MainActor func gatewayRequestRejectsCycleBeforeReenteringHandler() async throws {
    let transport = SignalTransport()
    let source = try await transport.register(address: "caller", incarnation: "one") { _ in }
    let target = try await transport.register(address: "receiver", incarnation: "one") { _ in }
    let descriptor = try integerSignalProtocol()
    try await transport.registerRequest(descriptor, endpoint: source) { $0 }
    try await transport.registerRequest(descriptor, endpoint: target) { value in
        try await transport.request(source: target, target: source, using: descriptor, request: value)
    }
    await #expect(throws: SignalTransportError.cyclicRequest) {
        try await transport.request(source: source, target: target, using: descriptor, request: 1)
    }
    await transport.shutdown()
}

private actor GatewayEventValues {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
private func gatewayEventEnvelope(_ id: String = UUID().uuidString) -> SignalEnvelope {
    .init(id: id, sessionID: "session", contract: "fixture.events.v1", payloadBytes: 8)
}
private func awaitEventBranchDrain(_ events: SignalEventTransport, target: SignalEndpoint) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await events.pendingBranches(to: target) != 0 {
        guard ContinuousClock.now < deadline else { throw GatewayTestError.cleanup }
        await Task.yield()
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func gatewayEventsKeepSubscriberQueuesIndependentAndPreserveChannelOrder() async throws {
    let config = try SignalEventConfiguration(
        publications: 8, branches: 16, bytes: 65536, branchCapacity: 2,
        controlSlots: 1, controlBytes: 1024, observers: 1)
    let transport = SignalTransport(eventConfiguration: config)
    let events = try await transport.events()
    let source = try await transport.register(address: "source", incarnation: "one") { _ in }
    let another = try await transport.register(address: "another", incarnation: "one") { _ in }
    let slowValues = GatewayEventValues()
    let fastValues = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(8))
    var fast = fastValues.stream.makeAsyncIterator()
    let entered = GatewayTestGate()
    let release = GatewayTestGate()
    let slow = try await transport.register(address: "slow", incarnation: "one") { signal in
        let value = try #require(signal.payload as? Int)
        if value == 0 {
            await entered.release()
            await release.wait()
        }
        await slowValues.append(value)
    }
    let quick = try await transport.register(address: "quick", incarnation: "one") { signal in
        fastValues.continuation.yield(try #require(signal.payload as? Int))
    }
    let descriptor = try SignalEventProtocol<Int>(id: "fixture.events.v1", maximumBytes: 8, measure: { _ in 8 })
    let channel = try EventChannel("fixture.events")
    let publisher = try await events.registerProducer(endpoint: source, channel: channel, using: descriptor)
    let secondPublisher = try await events.registerProducer(endpoint: another, channel: channel, using: descriptor)
    _ = try await events.subscribe(endpoint: slow, channel: channel, using: descriptor, sources: ["source", "another"])
    _ = try await events.subscribe(
        endpoint: quick, channel: channel, using: descriptor, sources: ["source", "another"])
    var receipts: [SignalPublication] = []
    for value in 0..<4 {
        receipts.append(
            try await events.publish(
                value, from: value.isMultiple(of: 2) ? publisher : secondPublisher, envelope: gatewayEventEnvelope()))
        if value == 0 { await entered.wait() }
        #expect(await fast.next() == value)
        try await awaitEventBranchDrain(events, target: quick)
    }
    let rejected = try await events.wait(receipts[2])
    #expect(rejected.contains { $0.target == "slow" && $0.status == .rejected && $0.reason == "capacityExceeded" })
    #expect(rejected.contains { $0.target == "quick" && $0.status == .accepted })
    await release.release()
    await events.flush()
    #expect(await slowValues.values == [0, 1])
    await transport.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func gatewayEventFullSubscriberQueueDoesNotConsumeSharedBranchBudget() async throws {
    let config = try SignalEventConfiguration(
        publications: 8, branches: 6, bytes: 65536, branchCapacity: 2,
        controlSlots: 1, controlBytes: 1024, observers: 1)
    let transport = SignalTransport(eventConfiguration: config)
    let events = try await transport.events()
    let source = try await transport.register(address: "source", incarnation: "one") { _ in }
    let fastValues = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(8))
    var fast = fastValues.stream.makeAsyncIterator()
    let entered = GatewayTestGate()
    let release = GatewayTestGate()
    let slow = try await transport.register(address: "slow", incarnation: "one") { signal in
        if try #require(signal.payload as? Int) == 0 {
            await entered.release()
            await release.wait()
        }
    }
    let quick = try await transport.register(address: "quick", incarnation: "one") { signal in
        fastValues.continuation.yield(try #require(signal.payload as? Int))
    }
    let descriptor = try SignalEventProtocol<Int>(id: "fixture.events.v1", maximumBytes: 8, measure: { _ in 8 })
    let channel = try EventChannel("fixture.events")
    let publisher = try await events.registerProducer(endpoint: source, channel: channel, using: descriptor)
    _ = try await events.subscribe(endpoint: slow, channel: channel, using: descriptor, sources: ["source"])
    _ = try await events.subscribe(endpoint: quick, channel: channel, using: descriptor, sources: ["source"])
    var receipts: [SignalPublication] = []
    for value in 0..<3 {
        receipts.append(try await events.publish(value, from: publisher, envelope: gatewayEventEnvelope()))
        if value == 0 { await entered.wait() }
        #expect(await fast.next() == value)
        try await awaitEventBranchDrain(events, target: quick)
    }
    let results = try await events.wait(receipts[2])
    #expect(results.contains { $0.target == "slow" && $0.status == .rejected && $0.reason == "capacityExceeded" })
    #expect(results.contains { $0.target == "quick" && $0.status == .accepted })
    await release.release()
    await events.flush()
    await transport.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func gatewayEventSubscriptionCancellationJoinsOnlyItsOwnBranch() async throws {
    let transport = SignalTransport()
    let events = try await transport.events()
    let source = try await transport.register(address: "source", incarnation: "one") { _ in }
    let entered = GatewayTestGate()
    let joined = GatewayCounter()
    let received = GatewayCounter()
    let slow = try await transport.register(address: "slow", incarnation: "one") { _ in
        await entered.release()
        do { try await Task.sleep(for: .seconds(60)) } catch {
            await joined.increment()
            throw error
        }
    }
    let quick = try await transport.register(address: "quick", incarnation: "one") { _ in await received.increment() }
    let descriptor = try SignalEventProtocol<Int>(id: "fixture.events.v1", maximumBytes: 8, measure: { _ in 8 })
    let channel = try EventChannel("fixture.events")
    let publisher = try await events.registerProducer(endpoint: source, channel: channel, using: descriptor)
    let subscription = try await events.subscribe(
        endpoint: slow, channel: channel, using: descriptor, sources: ["source"])
    _ = try await events.subscribe(endpoint: quick, channel: channel, using: descriptor, sources: ["source"])
    let first = try await events.publish(1, from: publisher, envelope: gatewayEventEnvelope())
    await entered.wait()
    await events.cancel(subscription)
    #expect(await joined.count == 1)
    let outcomes = try await events.wait(first)
    #expect(outcomes.contains { $0.target == "quick" && $0.status == .accepted })
    let second = try await events.publish(2, from: publisher, envelope: gatewayEventEnvelope())
    _ = try await events.wait(second)
    #expect(await received.count == 2)
    #expect(await joined.count == 1)
    await transport.shutdown()
}

@Test(.actionCatalog) @MainActor
func gatewayEventBindingsAreExplicitVersionedAndFilterVariants() async throws {
    #expect(throws: SignalTransportError.invalidEnvelope) { try EventChannel("fixture") }
    #expect(throws: SignalTransportError.invalidEnvelope) { try EventChannel("fixture.events.v1") }
    let transport = SignalTransport()
    let events = try await transport.events()
    let source = try await transport.register(address: "source", incarnation: "one") { _ in }
    let count = GatewayCounter()
    let target = try await transport.register(address: "target", incarnation: "one") { _ in await count.increment() }
    let descriptor = try SignalEventProtocol<Int>(
        id: "fixture.events.v1", variants: ["partial", "final"], maximumBytes: 8,
        measure: { _ in 8 }, variant: { $0 == 0 ? "partial" : "final" })
    let channel = try EventChannel("fixture.events")
    let publisher = try await events.registerProducer(endpoint: source, channel: channel, using: descriptor)
    _ = try await events.subscribe(
        endpoint: target, channel: channel, using: descriptor, sources: ["source"], variants: ["final"])
    _ = try await events.wait(events.publish(0, from: publisher, envelope: gatewayEventEnvelope()))
    #expect(await count.count == 0)
    _ = try await events.wait(events.publish(1, from: publisher, envelope: gatewayEventEnvelope()))
    #expect(await count.count == 1)
    await #expect(throws: SignalTransportError.schemaMismatch) {
        try await events.registerProducer(
            endpoint: source, channel: channel,
            using: SignalEventProtocol<String>(
                id: "fixture.events.v1", variants: ["partial", "final"], maximumBytes: 8, measure: { _ in 8 }))
    }
    _ = try await transport.register(address: "source", incarnation: "two") { _ in }
    await #expect(throws: SignalTransportError.staleEndpoint) {
        try await events.publish(1, from: publisher, envelope: gatewayEventEnvelope())
    }
    await transport.shutdown()
}

@Test func invocationSnapshotRoundTripPreservesEmptyAndArchivedArguments() throws {
    let original = try ActionInvocationSnapshot(
        .init(actionPath: gatewayPath, parameters: ["text": "", "source": "用户原文\n\\$()"]))
    let decoded = try JSONDecoder().decode(ActionInvocationSnapshot.self, from: JSONEncoder().encode(original))
    #expect(decoded == original && decoded.arguments?["text"] == "" && decoded.arguments?["missing"] == nil)
    let large = try ActionInvocationSnapshot(
        .init(
            actionPath: gatewayPath,
            parameters: ["text": String(repeating: "x", count: ActionInvocationSnapshot.inlineBytes + 1)]))
    let bytes = try JSONEncoder().encode(large)
    let archived = try large.archived(at: UUID().uuidString)
    let reference = try JSONDecoder().decode(ActionInvocationSnapshot.self, from: JSONEncoder().encode(archived))
    #expect(reference.arguments == nil && reference.reference != nil)
    #expect(try reference.restoring(from: bytes).arguments == large.arguments)
    #expect(throws: (any Error).self) { try reference.restoring(from: JSONEncoder().encode(original)) }
    #expect(throws: ActionInvocationSnapshot.InvalidSnapshot.capacityExceeded) {
        try ActionInvocationSnapshot(
            .init(
                actionPath: gatewayPath,
                parameters: ["text": String(repeating: "x", count: ActionInvocationSnapshot.maximumBytes)]))
    }
}

private actor OwnedEventSubscription {
    private var value: SignalEventSubscription?
    func install(_ value: SignalEventSubscription) { self.value = value }
    func close(_ broker: SignalEventTransport) async {
        if let value {
            self.value = nil
            await broker.cancel(value)
        }
    }
}

@Test(.actionCatalog) func consumerCanCloseItsSubscriptionAfterConsumptionWithoutCancellingItsAcknowledgment()
    async throws
{
    let transport = SignalTransport()
    let events = try await transport.events()
    let owner = OwnedEventSubscription()
    let received = GatewayCounter()
    let source = try await transport.register(address: "source", incarnation: "one") { _ in }
    let target = try await transport.register(address: "consumer", incarnation: "one") { _ in
        await received.increment()
        await owner.close(events)
    }
    let descriptor = try SignalEventProtocol<Int>(id: "fixture.events.v1", maximumBytes: 8, measure: { _ in 8 })
    let channel = try EventChannel("fixture.events")
    let publisher = try await events.registerProducer(endpoint: source, channel: channel, using: descriptor)
    await owner.install(
        try await events.subscribe(
            endpoint: target, channel: channel, using: descriptor, sources: ["source"], scope: "owned",
            sessionID: "session"))
    let wrongSession = SignalEnvelope(
        id: UUID().uuidString, sessionID: "other", contract: descriptor.id, payloadBytes: 8)
    #expect(try await events.wait(events.publish(0, from: publisher, envelope: wrongSession, scope: "owned")).isEmpty)
    #expect(await received.count == 0)
    #expect(
        try await events.wait(events.publish(1, from: publisher, envelope: gatewayEventEnvelope(), scope: "other"))
            .isEmpty)
    let outcomes = try await events.wait(
        events.publish(2, from: publisher, envelope: gatewayEventEnvelope(), scope: "owned"))
    #expect(outcomes.count == 1 && outcomes[0].status == .accepted)
    #expect(
        try await events.wait(events.publish(3, from: publisher, envelope: gatewayEventEnvelope(), scope: "owned"))
            .isEmpty)
    #expect(await received.count == 1)
    await transport.shutdown()
}

@Test(.actionCatalog) @MainActor func unscopedEventSubscriptionReceivesAllScopesWithoutOverlappingBindings()
    async throws
{
    let transport = SignalTransport()
    let source = try await transport.register(address: "source", incarnation: "one") { _ in }
    let values = GatewayEventValues()
    let target = try await transport.register(address: "target", incarnation: "one") { input in
        try await values.append(#require(input.payload as? Int))
    }
    let events = try await transport.events()
    let channel = try EventChannel("fixture.events")
    let descriptor = try SignalEventProtocol<Int>(id: "fixture.events.v1", maximumBytes: 8, measure: { _ in 8 })
    let publisher = try await events.registerProducer(endpoint: source, channel: channel, using: descriptor)
    let subscription = try await events.subscribe(
        endpoint: target, channel: channel, using: descriptor, sources: ["source"])
    await #expect(throws: SignalTransportError.duplicateProtocol) {
        try await events.subscribe(
            endpoint: target, channel: channel, using: descriptor, sources: ["source"], scope: "task-a")
    }
    for (value, scope) in [(1, Optional("task-a")), (2, Optional("task-b")), (3, nil)] {
        let receipt = try await events.publish(value, from: publisher, envelope: gatewayEventEnvelope(), scope: scope)
        #expect(try await events.wait(receipt).first?.status == .accepted)
    }
    #expect(await values.values == [1, 2, 3])
    await events.cancel(subscription)
    await transport.shutdown()
}

@Test func gatewayRejectsMissingAndWrongKindChannelsBeforeDelivery() async throws {
    let transport = SignalTransport()
    let count = GatewayCounter()
    let source = try await transport.register(address: "source", incarnation: "one") { _ in }
    let target = try await transport.register(address: "receiver", incarnation: "one", sendChannels: ["named.direct"]) {
        _ in
        await count.increment()
    }
    let descriptor = try SignalEventProtocol<Int>(id: "fixture.events.v1", maximumBytes: 8, measure: { _ in 8 })
    let bus = try await transport.events()
    let publisher = try await bus.registerProducer(
        endpoint: source, channel: EventChannel("named.events"), using: descriptor)
    await #expect(throws: SignalTransportError.channelUnavailable("named.direct")) {
        try await transport.declareChannel("named.direct", kind: .pubSub, endpoint: source)
    }
    for name in ["absent.channel", "named.events"] {
        await #expect(throws: SignalTransportError.channelUnavailable(name)) {
            try await transport.send(
                source: source, target: target,
                envelope: .init(
                    id: "id", sessionID: "session", contract: descriptor.id, channel: name, payloadBytes: 8), payload: 1
            )
        }
    }
    await #expect(throws: SignalTransportError.channelUnavailable("named.direct")) {
        try await bus.publish(
            1, from: publisher,
            envelope: .init(
                id: "id", sessionID: "session", contract: descriptor.id, channel: "named.direct", payloadBytes: 8))
    }
    let request = try integerSignalProtocol(timeout: .seconds(30))
    try await transport.registerRequest(request, endpoint: target, channel: "named.direct") { value in
        await count.increment()
        return value
    }
    await #expect(throws: SignalTransportError.channelUnavailable("named.events")) {
        try await transport.request(
            source: source, target: target, using: request, request: 1,
            envelope: .init(
                id: "id", sessionID: "session", contract: request.id, channel: "named.events", payloadBytes: 8))
    }
    #expect(await count.count == 0)
    #expect(try await transport.request(source: source, target: target, using: request, request: 3) == 3)
    #expect(await count.count == 1)
    await transport.shutdown()
}
