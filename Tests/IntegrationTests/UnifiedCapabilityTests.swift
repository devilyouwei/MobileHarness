import ActionRuntime
import Actions
import AgentCore
import Foundation
import Gateway
import Testing

private struct UnifiedFixtureModule: CapabilityModule {
    let definitions: [ActionDefinition]
}
private actor UnifiedFixtureLog {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

@Test func oneImplementationReturnsTheSameValueThroughBothProtocols() async throws {
    let log = UnifiedFixtureLog()
    let path = ActionIdentifier(domain: "Fixture", module: "Query", function: "read")
    let definition = ActionDefinition(
        path: path, displayName: "Read", kind: .finite, completion: "Return the selected value.",
        serializationKey: "fixture.query", protocols: [.action, .tool], directResultPolicy: .returning,
        resolvingResources: { request in
            [ActionResource(rawValue: "fixture." + (request.parameters["target"] ?? "missing"))]
        }, estimatingDuration: { _ in try .init(expected: .zero, timeout: .seconds(2)) },
        completing: { invocation in
            await log.record(invocation.context.source)
            return .value(invocation.call.parameters["target"] ?? "missing")
        })
    let module = UnifiedFixtureModule(definitions: [definition])
    let actionRegistry = try ActionRegistry(modules: [module.actions])
    let toolRegistry = try ToolRegistry(modules: [module.tools])
    let session = UUID()
    let input = UUID()
    let correlation = UUID()
    let context = ActionExecutionContext(
        source: "fixture", sessionID: session, inputID: input,
        sequence: 4, correlationID: correlation, ordinal: 2)
    let scheduled = ActionInvocation(
        call: .init(actionPath: path, channel: "main", parameters: ["target": "one"]),
        context: context)
    #expect(try await ActionExecutor(registry: actionRegistry).execute(scheduled) == .value("one"))
    let call = ToolRequest(toolPath: path.description, arguments: ["target": "one"])
    #expect(try await toolRegistry.resources(for: call) == [ActionResource(rawValue: "fixture.one")])
    #expect(try await toolRegistry.timeout(for: call) == .seconds(2))
    let result = try await ToolExecutor(registry: toolRegistry).execute(
        call,
        context: .init(
            source: "fixture", sessionID: session, inputID: input, sequence: 4,
            correlationID: correlation, ordinal: 2))
    #expect(result?.completion == .value("one"))
    #expect(result?.value == "one" && result?.callID == call.id && result?.isError == false)
    #expect(await log.values == ["fixture", "fixture"])
}

@Test func oneGazeFunctionRunsScheduledAndDirectWithPreservedContext() async throws {
    let log = UnifiedFixtureLog()
    let definition = UIActions.moveEyesDefinition(completing: { call, context in
        try await UIActions.moveEyes(invocation: .init(call: call, context: context)) { _, invocation in
            await log.record(invocation.context.source + ":" + String(invocation.context.sequence))
        }
    }).exposed(as: [.action, .tool])
    let module = UnifiedFixtureModule(definitions: [definition])
    let scheduler = ChannelScheduler(registry: try ActionRegistry(modules: [module.actions]))
    let input = AgentInput(sessionID: UUID(), payload: .event("fixture"))
    let call = ActionCall(
        actionPath: .init(domain: "UI", module: "Gaze", function: "moveEyes"),
        channel: "Display", parameters: ["x": "0.2", "y": "0.3"])
    let agent = AgentID(rawValue: "fixture")
    try await scheduler.enqueue(invocation: ActionInvocation(source: agent, input: input, call: call, sequence: 7))
    try await scheduler.finish(inputID: input.id, source: agent)
    let tool = ToolRequest(toolPath: definition.path.description, arguments: ["x": "0.2", "y": "0.3"])
    let result = try await ToolExecutor(registry: ToolRegistry(modules: [module.tools])).execute(
        tool,
        context: .init(source: "fixture", sessionID: input.sessionID, inputID: input.id, sequence: 8))
    #expect(result == nil)
    #expect(await log.values == ["fixture:7", "fixture:8"])
}

@Test func implementationProtocolAvailabilityDoesNotGrantAgentPermission() throws {
    let path = ActionPath(domain: "Fixture", module: "Query", function: "read")
    let module = UnifiedFixtureModule(definitions: [
        ActionDefinition(path: path.description, handler: { _ in "ok" })
    ])
    let permissions = try CapabilityRegistry(internalActions: [
        InternalAction(domain: "Fixture", module: "Query", function: "read", channel: "main")
    ])
    #expect(throws: ActionExecutionError.missingHandler(path.executionIdentifier)) {
        try BehaviorCoverage.validate(
            actions: ActionRegistry(modules: [module.actions]),
            toolPaths: [path.description], capabilities: [permissions])
    }
    #expect(!permissions.permits(ToolCall(toolPath: path.description)))
}

private actor UnifiedGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}
private actor UnifiedReceiptAgent: Agent {
    nonisolated let descriptor: AgentDescriptor
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    private var lifecycle: AgentLifecycle = .registered
    private(set) var receipts: [ToolResult] = []
    init(capabilities: CapabilityRegistry) {
        descriptor = .init(
            id: .init(rawValue: "fixture"), name: "Unified fixture", inputs: [.toolResult],
            outputs: [.actionCall, .toolCall], capabilities: capabilities)
    }
    func start() { lifecycle = .running }
    func pause() { lifecycle = .paused }
    func resume() { lifecycle = .running }
    func stop() { lifecycle = .stopped }
    func status() -> AgentStatus { .init(lifecycle: lifecycle, queuedInputs: 0, processedInputs: receipts.count) }
    func receive(_ input: AgentInput) throws {
        guard lifecycle == .running, case .toolResult(let result) = input.payload else {
            throw HarnessError.unsupportedInput
        }
        guard receipts.count < 8 else { throw HarnessError.queueFull }
        receipts.append(result)
    }
}

@Test(.timeLimit(.minutes(1))) func nativeToolUsesSharedSchedulingAndJoinsCancellationCleanup() async throws {
    let started = UnifiedGate()
    let release = UnifiedGate()
    let nativeStarted = UnifiedGate()
    let cleaned = UnifiedGate()
    let log = UnifiedFixtureLog()
    let path = ActionIdentifier(domain: "Fixture", module: "Work", function: "run")
    let definition = ActionDefinition(
        path: path, displayName: "Work", kind: .finite,
        completion: "Return after work or joined cleanup.", serializationKey: "fixture.work",
        protocols: [.action, .tool], executionPolicy: .scheduled(channel: "native"), directResultPolicy: .returning,
        completing: { invocation in
            let mode = invocation.call.parameters["mode"] ?? "missing"
            await log.record(mode + ":" + invocation.context.inputID.uuidString)
            if mode == "first" {
                await started.open()
                await release.wait()
            }
            if mode == "hold" {
                await nativeStarted.open()
                do { try await Task.sleep(for: .seconds(20)) } catch {
                    await cleaned.open()
                    throw error
                }
            }
            return .value(mode)
        })
    let module = UnifiedFixtureModule(definitions: [definition])
    let scheduler = ChannelScheduler(registry: try ActionRegistry(modules: [module.actions]))
    let permissions = try CapabilityRegistry(
        tools: [ToolRegistration(alias: "run", path: path.description, requiredParameters: ["mode"])],
        internalActions: [
            InternalAction(domain: "Fixture", module: "Work", function: "run", channel: "main", required: ["mode"])
        ])
    let agent = UnifiedReceiptAgent(capabilities: permissions)
    let manager = AgentManager()
    let session = UUID()
    try await manager.register(agent, sessionID: session)
    try await manager.start(agent.descriptor.id)
    let gateway = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager),
        tools: try ToolRegistry(modules: [module.tools]), actions: scheduler, sink: { _ in })
    let first = AgentInput(sessionID: session, payload: .event("fixture"))
    try await gateway.dispatch(
        .init(
            source: agent.descriptor.id, input: first,
            output: .actionCall(
                .init(
                    actionPath: .init(domain: path.domain, module: path.module, function: path.function),
                    channel: "main", parameters: ["mode": "first"])), sequence: 1))
    await started.wait()
    let native = AgentInput(sessionID: session, payload: .event("native"))
    let observations = try await scheduler.observeExecutions()
    let call = ToolCall(toolPath: path.description, arguments: ["mode": "second"])
    let work = Task {
        try await gateway.dispatch(
            .init(source: agent.descriptor.id, input: native, output: .toolCall(call), sequence: 2))
    }
    for await snapshot in observations { if snapshot.records.count == 2 { break } }
    #expect(await log.values == ["first:" + first.id.uuidString])
    await release.open()
    let result = try await work.value
    #expect(result?.completion == .value("second") && result?.callID == call.id)
    #expect(await log.values == ["first:" + first.id.uuidString, "second:" + native.id.uuidString])
    let receipts = await agent.receipts
    #expect(receipts.count == 1 && receipts.first?.completion == .value("second"))
    try await scheduler.finish(inputID: first.id, source: agent.descriptor.id)
    let held = AgentInput(sessionID: session, payload: .event("hold"))
    let cancellation = Task {
        try await gateway.dispatch(
            .init(
                source: agent.descriptor.id, input: held,
                output: .toolCall(.init(toolPath: path.description, arguments: ["mode": "hold"])), sequence: 3))
    }
    await nativeStarted.wait()
    cancellation.cancel()
    await #expect(throws: CancellationError.self) { try await cancellation.value }
    await cleaned.wait()
    #expect(await scheduler.executionSnapshot().records.last?.phase == .cancelled)
    #expect(await agent.receipts.count == 1)
    await gateway.shutdown()
}

@Test func canonicalCatalogRejectsCrossProtocolDuplicatesAndHiddenInvalidMetadata() throws {
    let path = ActionIdentifier(domain: "Fixture", module: "Work", function: "run")
    let scheduled = ActionDefinition(
        path: path, displayName: "Run", kind: .finite, completion: "Completed.", handler: { _ in })
    let native = ActionDefinition(path: path.description, completing: { _, _ in })
    #expect(throws: ActionExecutionError.duplicateDefinition(path)) {
        try CapabilityCatalog(modules: [UnifiedFixtureModule(definitions: [scheduled, native])])
    }
    let hidden = scheduled.exposed(as: [])
    #expect(throws: ActionExecutionError.invalidDefinition(path)) {
        try CapabilityCatalog(modules: [UnifiedFixtureModule(definitions: [hidden])])
    }
}
