import ActionBindings
import Actions
import AgentBindings
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import Storage
import Testing

private struct UnifiedFixtureModule: ActionBindingModule {
    let definitions: [ActionBinding]
}
private actor UnifiedFixtureLog {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

@Test(.actionCatalog) func oneImplementationReturnsTheSameValueThroughBothProtocols() async throws {
    let session = UUID().uuidString
    let input = UUID().uuidString
    let correlation = UUID().uuidString
    let context = ActionExecutionContext(
        source: "fixture", sessionID: session, inputID: input,
        sequence: 4, correlationID: correlation, ordinal: 2)
    let log = UnifiedFixtureLog()
    let path = ActionIdentifier(domain: "Fixture", module: "Query", function: "read")
    let function = ActionFunction(
        path: path, displayName: "Read", kind: .finite, completion: "Return the selected value.",
        resolvingResources: { request in
            [ActionResource(rawValue: "fixture." + (request.parameters["target"] ?? "missing"))]
        }, dynamicTimeout: { _ in try .init(expected: .zero, timeout: .seconds(2)) },
        completing: { invocation in
            #expect(invocation.context == context)
            await log.record(invocation.context.source)
            return .value(invocation.call.parameters["target"] ?? "missing")
        })
    let actionBinding = ActionBinding(function: function)
    let toolBinding = ActionBinding(
        function: function, protocols: [.tool], executionPolicy: .direct, directResultPolicy: .returning)
    let actionRegistry = try ActionRegistry(definitions: [actionBinding])
    let toolRegistry = try ToolRegistry(modules: [UnifiedFixtureModule(definitions: [toolBinding]).tools])
    let scheduled = ActionInvocation(
        call: .init(actionPath: path, channel: "main", parameters: ["target": "one"]),
        context: context, executionID: UUID().uuidString)
    #expect(try await ActionExecutor(registry: actionRegistry).execute(scheduled) == .value("one"))
    let call = ToolRequest(id: UUID().uuidString, toolPath: path.description, arguments: ["target": "one"])
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

@Test(.actionCatalog) func oneGazeFunctionRunsScheduledAndDirectWithPreservedContext() async throws {
    let log = UnifiedFixtureLog()
    let definition = ActionBinding(
        function: UIActions.moveEyesDefinition(handler: { invocation in
            try await UIActions.moveEyes(invocation: invocation) { _, invocation in
                await log.record(invocation.context.source + ":" + String(invocation.context.sequence))
            }
        }), protocols: [.action, .tool], executionPolicy: .direct
    ).exposed(as: [.action, .tool])
    let module = UnifiedFixtureModule(definitions: [definition])
    let scheduler = ChannelScheduler(registry: try ActionRegistry(modules: [module.actions]))
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture"))
    let call = ActionCall(
        actionPath: .init(domain: "UI", module: "Gaze", function: "moveEyes"),
        channel: "Display", parameters: ["x": "0.2", "y": "0.3"])
    let agent = AgentID(rawValue: "fixture")
    try await scheduler.enqueue(invocation: ActionInvocation(source: agent, input: input, call: call, sequence: 7))
    try await scheduler.finish(inputID: input.id, source: agent)
    let tool = ToolRequest(
        id: UUID().uuidString, toolPath: definition.path.description, arguments: ["x": "0.2", "y": "0.3"])
    let result = try await ToolExecutor(registry: ToolRegistry(modules: [module.tools])).execute(
        tool,
        context: .init(source: "fixture", sessionID: input.sessionID, inputID: input.id, sequence: 8))
    #expect(result == nil)
    #expect(await log.values == ["fixture:7", "fixture:8"])
}

@Test(.actionCatalog) func implementationProtocolAvailabilityDoesNotGrantAgentPermission() throws {
    let path = ActionPath(domain: "Fixture", module: "Query", function: "read")
    let module = UnifiedFixtureModule(definitions: [
        ActionBinding(path: path.description, handler: { _ in "ok" })
    ])
    let permissions = try CapabilityRegistry(internalActions: [
        InternalAction(domain: "Fixture", module: "Query", function: "read", channel: "main")
    ])
    #expect(throws: ActionExecutionError.missingHandler(path.executionIdentifier)) {
        try BehaviorCoverage.validate(
            actions: ActionRegistry(modules: [module.actions]),
            toolPaths: [path.description], capabilities: [permissions])
    }
    #expect(!permissions.permits(ToolCall(id: UUID().uuidString, toolPath: path.description)))
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

@Test(.actionCatalog, .timeLimit(.minutes(1))) func nativeToolUsesSharedResourcesAndJoinsCancellationCleanup()
    async throws
{
    let started = UnifiedGate()
    let release = UnifiedGate()
    let nativeStarted = UnifiedGate()
    let cleaned = UnifiedGate()
    let log = UnifiedFixtureLog()
    let path = ActionIdentifier(domain: "Fixture", module: "Work", function: "run")
    let definition = ActionBinding(
        path: path, displayName: "Work", kind: .finite,
        completion: "Return after work or joined cleanup.",
        protocols: [.action, .tool], executionPolicy: .direct, directResultPolicy: .returning,
        resources: [.init(rawValue: "fixture.work")],
        completing: { invocation in
            let mode = invocation.call.parameters["mode"] ?? "missing"
            await log.record(mode + ":" + invocation.context.inputID)
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
    let resources = try ResourceCoordinator(definitions: [
        ResourceDefinition(id: .init(rawValue: "fixture.work"), allowedOwners: [.init(rawValue: "fixture")]) {}
    ])
    let scheduler = ChannelScheduler(registry: try ActionRegistry(modules: [module.actions]), resources: resources)
    let permissions = try CapabilityRegistry(
        tools: [ToolRegistration(alias: "run", path: path.description, requiredParameters: ["mode"])],
        internalActions: [
            InternalAction(domain: "Fixture", module: "Work", function: "run", channel: "main", required: ["mode"])
        ])
    let agent = UnifiedReceiptAgent(capabilities: permissions)
    let manager = AgentManager()
    let session = UUID().uuidString
    try await manager.register(agent, sessionID: session)
    try await manager.start(agent.descriptor.id)
    let gateway = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, allowsExternalSend: true),
        tools: try ToolRegistry(modules: [module.tools]), actions: scheduler, sink: { _ in })
    let first = AgentInput(id: UUID().uuidString, sessionID: session, payload: .event("fixture"))
    try await gateway.dispatch(
        .init(
            source: agent.descriptor.id, input: first,
            output: .actionCall(
                .init(
                    actionPath: .init(domain: path.domain, module: path.module, function: path.function),
                    channel: "main", parameters: ["mode": "first"])), sequence: 1))
    await started.wait()
    let native = AgentInput(id: UUID().uuidString, sessionID: session, payload: .event("native"))
    let call = ToolCall(id: UUID().uuidString, toolPath: path.description, arguments: ["mode": "second"])
    let work = Task {
        try await gateway.execute(
            .init(source: agent.descriptor.id, input: native, output: .toolCall(call), sequence: 2))
    }
    let rejected = try await work.value
    #expect(rejected.isError == true)
    #expect(await log.values == ["first:" + first.id])
    await release.open()
    try await scheduler.finish(inputID: first.id, source: agent.descriptor.id)
    let result = try await gateway.dispatch(
        .init(
            source: agent.descriptor.id, input: native,
            output: .toolCall(
                ToolCall(id: UUID().uuidString, toolPath: path.description, arguments: call.arguments)),
            sequence: 2))
    #expect(result?.completion == .value("second"))
    #expect(await log.values == ["first:" + first.id, "second:" + native.id])
    let receipts = await agent.receipts
    #expect(receipts.count == 1 && receipts.last?.completion == .value("second"))
    try await scheduler.finish(inputID: first.id, source: agent.descriptor.id)
    let held = AgentInput(id: UUID().uuidString, sessionID: session, payload: .event("hold"))
    let cancellation = Task {
        try await gateway.dispatch(
            .init(
                source: agent.descriptor.id, input: held,
                output: .toolCall(
                    .init(id: UUID().uuidString, toolPath: path.description, arguments: ["mode": "hold"])),
                sequence: 3))
    }
    await nativeStarted.wait()
    cancellation.cancel()
    await #expect(throws: CancellationError.self) { try await cancellation.value }
    await cleaned.wait()
    #expect(await scheduler.executionSnapshot().records.count == 1)
    #expect(await agent.receipts.count == 1)
    await gateway.shutdown()
}

@Test(.actionCatalog) func canonicalCatalogRejectsCrossProtocolDuplicatesAndHiddenInvalidMetadata() throws {
    let path = ActionIdentifier(domain: "Fixture", module: "Work", function: "run")
    let scheduled = ActionBinding(
        path: path, displayName: "Run", kind: .finite, completion: "Completed.", handler: { _ in })
    let native = ActionBinding(path: path.description, completing: { _ in })
    #expect(throws: ActionExecutionError.duplicateDefinition(path)) {
        try ActionBindingCatalog(definitions: [scheduled, native])
    }
    let hidden = scheduled.exposed(as: [])
    #expect(throws: ActionExecutionError.invalidDefinition(path)) {
        try ActionBindingCatalog(definitions: [hidden])
    }
}

@Test(.actionCatalog) func normalizedNativeInvocationRetainsReportPrecedenceAndCallIdentity() async throws {
    let id = UUID().uuidString
    let context = ActionExecutionContext(
        source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString, sequence: 7,
        correlationID: UUID().uuidString, ordinal: 3)
    let report = try ActionReport(entries: [.init(path: "Fixture.Query.read", status: .succeeded)])
    let definition = ActionBinding(
        path: .init(domain: "Fixture", module: "Query", function: "read"),
        displayName: "Read", kind: .finite, completion: "Read acknowledged.",
        protocols: [.tool], executionPolicy: .direct,
        directResultPolicy: .returning,
        completing: { invocation in
            #expect(invocation.executionID == id)
            #expect(invocation.context == context)
            #expect(invocation.call.parameters == ["value": "native"])
            try await invocation.results.record(report)
            return .value("lower priority value")
        })
    let module = UnifiedFixtureModule(definitions: [definition])
    let response = try #require(
        try await ToolExecutor(registry: ToolRegistry(modules: [module.tools])).execute(
            ToolRequest(id: id, toolPath: "Fixture.Query.read", arguments: ["value": "native"]), context: context))
    #expect(response.callID == id && !response.isError)
    #expect(response.completion == .report(report))
}

private struct PureFunctionFixture: CapabilityModule {
    let definitions: [ActionFunction]
}

@Test(.actionCatalog) func pureCatalogValidatesBeforeRegistrationAndHostRejectsUnknownModules() throws {
    let path = ActionIdentifier(domain: "Fixture", module: "Query", function: "read")
    let function = ActionFunction(
        path: path, displayName: "Read", kind: .finite, completion: "Read completed.", handler: { _ in })
    #expect(throws: ActionExecutionError.duplicateDefinition(path)) {
        try CapabilityCatalog(modules: [PureFunctionFixture(definitions: [function, function])])
    }
    let invalid = ActionFunction(
        path: path, displayName: "", kind: .finite, completion: "Completed.", handler: { _ in })
    #expect(throws: ActionExecutionError.invalidDefinition(path)) {
        try CapabilityCatalog(modules: [PureFunctionFixture(definitions: [invalid])])
    }
    #expect(throws: (any Error).self) {
        try BehaviorAssembly(capabilityModules: [PureFunctionFixture(definitions: [function])])
    }
}

@Test(.actionCatalog) func producerFailureCodeIsIndependentOfCallProtocol() async throws {
    let log = UnifiedFixtureLog()
    let function = UIActions.moveEyesDefinition(handler: { invocation in
        try await UIActions.moveEyes(invocation: invocation) { _, _ in await log.record("effect") }
    })
    let path = function.path
    let invocation = ActionInvocation(
        call: .init(actionPath: path, channel: "main", parameters: ["x": "2", "y": "0"]),
        context: .init(
            source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString),
        executionID: UUID().uuidString)
    let action = try ActionExecutor(registry: ActionRegistry(definitions: [ActionBinding(function: function)]))
    do {
        _ = try await action.execute(invocation)
        Issue.record("Invalid arguments executed")
    } catch {
        #expect(ActionReport.code(for: error).rawValue == "invalidArguments")
    }
    let binding = ActionBinding(function: function, protocols: [.tool], executionPolicy: .direct)
    let native = try ToolExecutor(registry: ToolRegistry(modules: [UnifiedFixtureModule(definitions: [binding]).tools]))
    let response = try await native.execute(
        ToolRequest(
            id: UUID().uuidString, toolPath: path.description, arguments: invocation.call.parameters),
        context: invocation.context)
    #expect(response?.failureCode == .invalidArguments && response?.isError == true)
    #expect(await log.values.isEmpty)
}

@Test(.actionCatalog) func sharedFunctionRegistryOwnsImplementationResourcesAndBudgetAcrossProtocolViews() async throws
{
    let path = ActionIdentifier(domain: "Fixture", module: "Query", function: "read")
    let log = UnifiedFixtureLog()
    let function = ActionFunction(
        path: path, displayName: "Read", kind: .finite, completion: "Read completed.",
        resources: [.init(rawValue: "fixture.journal")], timeout: .seconds(2),
        completing: { input in
            await log.record(input.context.source)
            return .value("canonical")
        })
    let functions = try FunctionRegistry(definitions: [function])
    let shadow = ActionFunction(
        path: path, displayName: "Read", kind: .finite, completion: "Read completed.",
        completing: { _ in
            Issue.record("Registration must not replace the canonical handler")
            return .value("shadow")
        })
    let actions = try ActionRegistry(definitions: [ActionBinding(function: shadow)], functions: functions)
    let native = ActionBinding(
        function: shadow, protocols: [.tool], executionPolicy: .direct, directResultPolicy: .returning)
    let tools = try ToolRegistry(modules: [UnifiedFixtureModule(definitions: [native]).tools], functions: functions)
    let invocation = ActionInvocation(
        call: .init(actionPath: path, channel: "main"),
        context: .init(
            source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString),
        executionID: UUID().uuidString)
    #expect(try actions.definition(for: path).resources == function.resources)
    let call = ToolRequest(id: UUID().uuidString, toolPath: path.description)
    #expect(try await tools.resources(for: call) == function.resources)
    #expect(try await tools.timeout(for: call) == .seconds(2))
    #expect(try await ActionExecutor(registry: actions).execute(invocation) == .value("canonical"))
    #expect(try await ToolExecutor(registry: tools).execute(call, context: invocation.context)?.value == "canonical")
    #expect(await log.values == ["fixture", "fixture"])
}

@Test(.actionCatalog) func invocationFailurePreservesReportAndAllowsNextCall() async throws {
    let path = ActionIdentifier(domain: "Fixture", module: "Work", function: "run")
    let report = try ActionReport(entries: [
        .init(path: "step.motor1", status: .succeeded),
        .init(
            path: "step.motor2", status: .failed, code: .disconnected,
            details: ["failureDescription": "Motor feedback disconnected"]),
    ])
    let function = ActionFunction(
        path: path, displayName: "Work", kind: .finite, completion: "Return the measured outcome.",
        completing: { input in
            if input.call.parameters["mode"] == "fail" { throw ActionReportedError(report) }
            return .value("next completed")
        })
    let binding = ActionBinding(
        function: function, protocols: [.action, .tool],
        executionPolicy: .direct,
        directResultPolicy: .returning)
    let module = UnifiedFixtureModule(definitions: [binding])
    let permissions = try CapabilityRegistry(
        tools: [ToolRegistration(alias: "run", path: path.description, requiredParameters: ["mode"])])
    let agent = UnifiedReceiptAgent(capabilities: permissions)
    let manager = AgentManager()
    let session = UUID().uuidString
    try await manager.register(agent, sessionID: session)
    try await manager.start(agent.descriptor.id)
    let scheduler = ChannelScheduler(registry: try ActionRegistry(modules: [module.actions]))
    let gateway = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, allowsExternalSend: true),
        tools: try ToolRegistry(modules: [module.tools]), actions: scheduler, sink: { _ in })
    let failed = try await gateway.dispatch(
        .init(
            source: agent.descriptor.id,
            input: .init(id: UUID().uuidString, sessionID: session, payload: .event("failure")),
            output: .toolCall(
                .init(id: UUID().uuidString, toolPath: path.description, arguments: ["mode": "fail"])),
            sequence: 1))
    #expect(failed?.isError == true && failed?.failureCode?.rawValue == "disconnected")
    guard case .report(let returned) = failed?.completion else {
        Issue.record("Structured producer report was lost")
        return
    }
    #expect(returned.entries == report.entries)
    #expect(returned.failureDescription == "Motor feedback disconnected")
    let next = try await gateway.dispatch(
        .init(
            source: agent.descriptor.id,
            input: .init(id: UUID().uuidString, sessionID: session, payload: .event("next")),
            output: .toolCall(
                .init(id: UUID().uuidString, toolPath: path.description, arguments: ["mode": "next"])),
            sequence: 2))
    #expect(next?.completion == .value("next completed"))
    let receipts = await agent.receipts
    #expect(receipts.count == 2)
    guard case .report(let feedback) = receipts.first?.completion else {
        Issue.record("Structured feedback was lost")
        return
    }
    #expect(feedback.entries.map(\.path) == returned.entries.map(\.path))
    #expect(feedback.entries.map(\.details) == returned.entries.map(\.details))
    #expect(feedback.executionFailure?.rawValue == returned.executionFailure?.rawValue)
    #expect(feedback.failureDescription == returned.failureDescription)
    #expect(receipts.last?.completion == .value("next completed"))
}
