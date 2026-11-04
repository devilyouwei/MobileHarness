import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import StorageCore
import Testing

@testable import Agents

@Test(.actionCatalog) func lifecycleAndBoundedQueue() async throws {
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        capacity: 1, chat: FixedTextChat(),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("hello"))
    await #expect(throws: HarnessError.notRunning) { try await agent.receive(input) }
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    try await agent.pause()
    try await agent.receive(input)
    await #expect(throws: HarnessError.queueFull) { try await agent.receive(input) }
    #expect(await agent.status().queuedInputs == 1)
    try await agent.resume()
    #expect(await agent.status().processedInputs == 1)
    await agent.stop()
    await #expect(throws: HarnessError.invalidTransition) { try await agent.start() }
}

@Test(.actionCatalog) func outputOverflowFailsAgent() async throws {
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        outputCapacity: 2,
        chat: FixedTextChat(text: "<express emotion=\"happy\"/><express emotion=\"sad\"/><express emotion=\"love\"/>"),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    try await agent.start()
    try await agent.receive(
        AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("overflow")))
    for _ in 0..<1000 {
        if await agent.status().lifecycle == .failed { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await agent.status().lifecycle == .failed)
    await #expect(throws: HarnessError.notRunning) {
        try await agent.receive(
            AgentInput(
                id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("rejected")))
    }
    await agent.stop()
}

@Test(.actionCatalog) func capabilitiesRejectUndeclaredActions() throws {
    let descriptor = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: FixedTextChat(),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    ).descriptor
    #expect(throws: HarnessError.forbiddenFunction) {
        try OutputValidator.validate(.actionCall(expectedActionCall(name: "move")), descriptor: descriptor)
    }
    #expect(throws: HarnessError.forbiddenTool) {
        try OutputValidator.validate(
            .toolCall(ToolCall(id: UUID().uuidString, toolPath: "Fixture.Control.deletePhotos")),
            descriptor: descriptor)
    }
    try OutputValidator.validate(.scheduling(.beginWait), descriptor: descriptor)
    let restricted = AgentDescriptor(id: .assistant, name: "restricted", inputs: [.text], outputs: [.text])
    #expect(throws: HarnessError.forbiddenOutput) {
        try OutputValidator.validate(.control("start"), descriptor: restricted)
    }
    #expect(throws: HarnessError.forbiddenOutput) {
        try OutputValidator.validate(.scheduling(.beginWait), descriptor: restricted)
    }
}

private actor Recorder {
    var outputs: [OutputEnvelope] = []
    var actions = 0
    func record(_ output: OutputEnvelope) { outputs.append(output) }
    func act() { actions += 1 }
}

private struct StatusRoundTripChat: ChatCapability {
    var availability: CapabilityAvailability { .available }
    var supportsToolCalls: Bool { true }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if let result = request.messages.last, result.role == .tool {
            let text = result.content.contains("Fixture busy") ? "Fixture busy" : "runtime healthy"
            try pair.emitter.yield(.text(text))
            try pair.emitter.yield(.finished(.stop))
        } else {
            try pair.emitter.yield(.toolCall(.init(id: "runtime", name: "runtimeInfo", argumentsJSON: "{}")))
            try pair.emitter.yield(.finished(.toolCalls))
        }
        pair.emitter.finish()
        return pair.session
    }
}

@Test(.actionCatalog, arguments: [false, true]) func toolRoundTripPreservesSessionAndCallID(_ fails: Bool) async throws
{
    let manager = AgentManager()
    let agent = try FixtureNativeAgent(
        chat: StatusRoundTripChat(),
        context: try AgentContextRepository(
            agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    )
    try await manager.register(agent)
    let speechRequests = try await bindSpeechRequests(agent)
    try await manager.start(.assistant)
    let requests = InputGateway(manager: manager)
    let tools = ToolRegistry()
    try await tools.register("System.Runtime.runtimeInfo") { _ in
        if fails { throw ActionExecutionFailure(code: .init(rawValue: "busy"), message: "Fixture busy") }
        return "runtime healthy"
    }
    let recorder = Recorder()
    let actions = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            ActionPath(domain: "Speech", module: "Playback", function: "speak"): { _ in },
            ActionPath(domain: "UI", module: "Caption", function: "print"): { _ in },
        ]))
    let responses = await OutputGateway(manager: manager, requests: requests, tools: tools, actions: actions) {
        await recorder.record($0)
    }
    let session = UUID().uuidString
    let input = AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("query"))
    _ = try await manager.receiveLocally(input, to: .assistant)
    // Tool results now asynchronously admit synthesis before emitting playback.
    var iterator = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    let first = try #require(try await iterator.next())
    guard case .toolCall(let call) = first.output else {
        Issue.record("Expected tool call")
        return
    }
    #expect(first.inputID == input.id)
    let directResult = try #require(try await ToolExecutor(registry: tools).execute(call, envelope: first))
    #expect(directResult.callID == call.id)
    let delivered = try #require(try await responses.dispatch(first))
    #expect(delivered.isError == fails)
    #expect(delivered.failureCode?.rawValue == (fails ? "busy" : nil))
    #expect(delivered.deliveryFailure == nil)
    let reply = try #require(try await iterator.next())
    #expect(reply.sessionID == session)
    #expect(
        await speechRequests.restored(reply.output)
            == .actionCall(
                expectedActionCall(name: "say", parameters: ["text": fails ? "Fixture busy" : "runtime healthy"])))
    try await responses.dispatch(reply)
    #expect(await recorder.outputs.count == 2)
    await agent.stop()
    await responses.shutdown()
}

@Test(.actionCatalog) func functionDispatchResolvesAgentTagThroughRegisteredPath() async throws {
    let manager = AgentManager()
    try await manager.register(
        FixtureNativeAgent(
            chat: FixedTextChat(),
            context: try AgentContextRepository(
                agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
        ))
    let requests = InputGateway(manager: manager)
    let recorder = Recorder()
    let missing = await OutputGateway(manager: manager, requests: requests, tools: ToolRegistry()) { _ in }
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("test"))
    let envelope = OutputEnvelope(
        source: .assistant, context: input.context,
        output: .actionCall(expectedActionCall(name: "express", parameters: ["emotion": "smile"])),
        taskScope: input.taskScope)
    await #expect(throws: (any Error).self) { try await missing.dispatch(envelope) }
    let actions = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            ActionPath(domain: "UI", module: "Expression", function: "express"): { _ in await recorder.act() }
        ]))
    let responses = await OutputGateway(manager: manager, requests: requests, tools: ToolRegistry(), actions: actions) {
        _ in
    }
    try await responses.dispatch(envelope)
    try await responses.dispatch(
        OutputEnvelope(
            source: .assistant, context: input.context, output: .control("agent.finished"), taskScope: input.taskScope))
    #expect(await recorder.actions == 1)
    // The path is not a public tag: callers must use the agent's declared alias.
    await #expect(throws: HarnessError.forbiddenFunction) {
        try await responses.dispatch(
            OutputEnvelope(
                source: .assistant, context: input.context,
                output: .actionCall(expectedActionCall(name: "Display.express")), taskScope: input.taskScope))
    }
    await responses.shutdown()
}

@Test(.actionCatalog) func unknownAndFailingToolsReturnCorrelatedErrors() async throws {
    let registry = ToolRegistry()
    let unknown = ToolCall(id: UUID().uuidString, toolPath: "Fixture.Control.unknown")
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("tool"))
    let result = try #require(
        try await ToolExecutor(registry: registry).execute(
            unknown,
            envelope: OutputEnvelope(
                source: .assistant, context: input.context, output: .toolCall(unknown), taskScope: input.taskScope)))
    #expect(result.isError && result.callID == unknown.id)
    try await registry.register("Fixture.Control.broken") { _ in throw HarnessError.notRunning }
    let broken = ToolCall(id: UUID().uuidString, toolPath: "Fixture.Control.broken")
    let failure = try #require(
        try await ToolExecutor(registry: registry).execute(
            broken,
            envelope: OutputEnvelope(
                source: .assistant, context: input.context, output: .toolCall(broken), taskScope: input.taskScope)))
    #expect(failure.isError)
}

@Test(.actionCatalog) func completionToolsReturnFailureOutcomesAndPropagateCancellation() async throws {
    let registry = ToolRegistry()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("tool"))
    let call = ToolCall(id: UUID().uuidString, toolPath: "UI.Pose.showPose")
    let envelope = OutputEnvelope(
        source: .visionPerception, context: input.context, output: .toolCall(call), taskScope: input.taskScope)
    try await registry.registerCompletion("UI.Pose.showPose") { invocation in
        let origin = invocation.context
        #expect(invocation.executionID == call.id)
        #expect(invocation.call.parameters == call.arguments)
        #expect(origin.sessionID == input.sessionID)
        #expect(origin.source == AgentID.visionPerception.rawValue)
    }
    #expect(try await ToolExecutor(registry: registry).execute(call, envelope: envelope) == nil)
    await #expect(throws: ToolRegistryError.duplicateHandler) {
        try await registry.register("UI.Pose.showPose") { _ in "unexpected" }
    }
    try await registry.register("Fixture.Control.value") { _ in "" }
    await #expect(throws: ToolRegistryError.duplicateHandler) {
        try await registry.registerCompletion("Fixture.Control.value") { _ in }
    }
    let value = ToolCall(id: UUID().uuidString, toolPath: "Fixture.Control.value")
    let result = try #require(try await ToolExecutor(registry: registry).execute(value, envelope: envelope))
    #expect(result.value.isEmpty)  // Empty data is still a result, unlike Void completion.
    try await registry.registerCompletion("Fixture.Control.failure") { _ in throw HarnessError.notRunning }
    let failed = try #require(
        try await ToolExecutor(registry: registry).execute(
            ToolCall(id: UUID().uuidString, toolPath: "Fixture.Control.failure"), envelope: envelope))
    #expect(failed.isError)
    #expect(failed.value.contains("notRunning"))
    try await registry.registerCompletion("Fixture.Control.cancel") { _ in throw CancellationError() }
    let cancelled = try #require(
        try await ToolExecutor(registry: registry).execute(
            ToolCall(id: UUID().uuidString, toolPath: "Fixture.Control.cancel"), envelope: envelope))
    #expect(cancelled.isError)
    #expect(cancelled.failureCode == .cancelled)
}

@Test(.actionCatalog) func gatewayForwardsWaitBoundariesAndRejectsUnbalancedCompletion() async throws {
    let manager = AgentManager()
    try await manager.register(
        FixtureNativeAgent(
            chat: FixedTextChat(),
            context: try AgentContextRepository(
                agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
        ))
    let recorder = Recorder()
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(definitions: [
            ActionBinding(
                path: .init(domain: "UI", module: "Expression", function: "express"), displayName: "Expression",
                kind: .finite, completion: "Acknowledged",
                resolvingResources: { request in
                    if request.parameters["emotion"] == "missing" { throw ResourceError.busy }
                    return []
                }, handler: { _ in await recorder.act() })
        ]))
    let gateway = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: ToolRegistry(),
        actions: scheduler
    ) { _ in }
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("groups"))
    for _ in 0..<2 {
        try await gateway.dispatch(
            OutputEnvelope(
                source: .assistant, context: input.context, output: .scheduling(.beginWait), taskScope: input.taskScope)
        )
        try await gateway.dispatch(
            OutputEnvelope(
                source: .assistant, context: input.context,
                output: .actionCall(expectedActionCall(name: "express", parameters: ["emotion": "smile"])),
                taskScope: input.taskScope))
        let rejection = try await gateway.execute(
            OutputEnvelope(
                source: .assistant, context: input.context,
                output: .rejectedCall(
                    CallRejection(kind: .action, alias: "unknown", reason: .unknownCapability)),
                taskScope: input.taskScope))
        #expect(rejection.isError)
        try await gateway.dispatch(
            OutputEnvelope(
                source: .assistant, context: input.context, output: .scheduling(.endWait), taskScope: input.taskScope))
    }
    try await gateway.dispatch(
        OutputEnvelope(
            source: .assistant, context: input.context, output: .control("agent.finished"), taskScope: input.taskScope))
    #expect(await recorder.actions == 2)
    let malformed = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("malformed"))
    try await gateway.dispatch(
        OutputEnvelope(
            source: .assistant, context: malformed.context, output: .scheduling(.beginWait),
            taskScope: malformed.taskScope))
    await #expect(throws: ActionSchedulingError.invalidSchedule) {
        try await gateway.dispatch(
            OutputEnvelope(
                source: .assistant, context: malformed.context, output: .control("agent.finished"),
                taskScope: malformed.taskScope))
    }
    await gateway.shutdown()
}

@Test(.actionCatalog) func messageFailureIsRecordedWithoutFailingProducer() async throws {
    let port = AgentMessaging { _, _, _ in throw CommunicationError.scopeClosed }
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("fixture"))
    let report = try await port.sendResult(.transcript("hello", final: true), parent: input, to: .assistant)
    #expect(report.failure != nil)
    let history = await port.history.snapshot()
    #expect(history.count == 1)
    #expect(history.first?.inputID == input.id)
    #expect(history.first?.report.failure != nil)
    for _ in 0..<128 {
        _ = try await port.sendResult(.transcript("hello", final: true), parent: input, to: .assistant)
    }
    #expect(await port.history.snapshot().count == 128)
    #expect(await port.history.evictedCount == 1)
}

@Test(.actionCatalog) func gatewayAccumulatesCompletionToolFailureAndContinuesOtherOutputs() async throws {
    let manager = AgentManager()
    let agent = try RuntimeToolFixture()
    try await manager.register(agent)
    try await manager.start(.assistant)
    let registry = ToolRegistry()
    try await registry.registerCompletion("UI.Caption.print") { _ in throw HarnessError.notRunning }
    try await registry.registerCompletion("UI.Caption.beginReplyTurn") { _ in }
    let gateway = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: registry,
        sink: { _ in })
    let failures = try await gateway.observeFailures()
    var failureIterator = failures.makeAsyncIterator()
    #expect(await failureIterator.next()?.records.isEmpty == true)
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture"))
    let failedCall = try InternalTool(path: "UI.Caption.print", required: ["text"]).call(["text": "hello"])
    let first = try await gateway.execute(
        OutputEnvelope(
            source: .assistant, context: input.context, output: .toolCall(failedCall), taskScope: input.taskScope))
    #expect(first.isError)
    let failureSnapshot = try #require(await failureIterator.next())
    #expect(failureSnapshot.records.count == 1)
    #expect(failureSnapshot.records.first?.title == "UI.Caption.print")
    #expect(failureSnapshot.records.first?.message == first.tool?.value)
    #expect(first.tool?.failureCode == .handlerFailed)
    #expect(failureSnapshot.records.first?.failureCode == "handlerFailed")

    let nextCall = try InternalTool(path: "UI.Caption.beginReplyTurn").call([:])
    let second = try await gateway.execute(
        OutputEnvelope(
            source: .assistant, context: input.context, output: .toolCall(nextCall), taskScope: input.taskScope))
    #expect(!second.isError)
    for kind in [CallRejection.Kind.action, .tool] {
        for reason in [GenerationError.unknownCapability, .invalidParameters] {
            let rejected = try await gateway.execute(
                OutputEnvelope(
                    source: .assistant, context: input.context,
                    output: .rejectedCall(
                        CallRejection(kind: kind, alias: "bad", callID: UUID().uuidString, reason: reason)),
                    taskScope: input.taskScope))
            #expect(rejected.isError)
        }
    }
    let historyFailure = try await gateway.execute(
        OutputEnvelope(
            source: .assistant, context: input.context, output: .control("agent.historyError: fixture"),
            taskScope: input.taskScope))
    #expect(historyFailure.isError)
    let continued = try await gateway.execute(
        OutputEnvelope(
            source: .assistant, context: input.context, output: .toolCall(nextCall), taskScope: input.taskScope))
    #expect(!continued.isError)
    #expect(await gateway.executionResults().outputs.count == 8)
    // Coalesced observations retain all bounded failures, independent of Tool-result delivery.
    for _ in 0..<100 {
        _ = try await gateway.execute(
            OutputEnvelope(
                source: .assistant, context: input.context, output: .toolCall(failedCall), taskScope: input.taskScope))
    }
    let latest = try #require(await failureIterator.next())
    #expect(latest.records.count == 100)
    #expect(latest.evictedCount == 6)
    #expect(await gateway.executionResults().actions.records.isEmpty)
    var subscriptions = [failures]
    for _ in 0..<7 { subscriptions.append(try await gateway.observeFailures()) }
    await #expect(throws: OutputGateway.ObservationError.capacityExceeded) { _ = try await gateway.observeFailures() }
    await gateway.shutdown()
    withExtendedLifetime(subscriptions) {}

}

@Test(.actionCatalog) func toolDeadlineJoinsCleanupAndExplicitCancellationPropagates() async throws {
    let registry = ToolRegistry()
    let cleanup = Recorder()
    try await registry.registerCompletion("Fixture.Control.slow", timeout: .milliseconds(10)) { _ in
        do { try await Task.sleep(for: .seconds(60)) } catch {
            await cleanup.act()
            throw error
        }
    }
    let call = ToolRequest(id: UUID().uuidString, toolPath: "Fixture.Control.slow")
    let context = ActionExecutionContext(
        source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString, sequence: 1)
    let result = try #require(
        try await ToolExecutor(registry: registry).execute(
            call, context: context))
    #expect(result.isError)
    #expect(result.value.contains("timed out"))
    #expect(result.failureCode == .timedOut)
    #expect(await cleanup.actions == 1)
    let task = Task { try await ToolExecutor(registry: registry).execute(call, context: context) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test(.actionCatalog) func toolFeedbackRejectionPreservesSuccessfulExecutionValue() async throws {
    let manager = AgentManager()
    let agent = try RuntimeToolFixture()
    try await manager.register(agent)
    try await manager.start(.assistant)
    try await agent.pause()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("occupied"))
    try await agent.receive(input)
    let tools = ToolRegistry()
    try await tools.register("UI.Caption.print") { _ in "completed value" }
    let gateway = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: tools,
        sink: { _ in })
    let result = try await gateway.execute(
        OutputEnvelope(
            source: .assistant, context: input.context,
            output: .toolCall(
                ToolCall(id: UUID().uuidString, toolPath: "UI.Caption.print", arguments: ["text": "fixture"])
            ), taskScope: input.taskScope))
    #expect(result.isError)
    #expect(result.tool?.value == "completed value")
    #expect(result.tool?.isError == false)
    #expect(result.failure != nil)
    #expect(result.failureCode == .deliveryFailed)
    #expect(result.tool?.failureCode == nil)
    await agent.stop()
}

private enum ToolTimeoutFixture {
    @Action(
        domain: "Fixture", module: "Control", title: "Slow fixture",
        timeout: .milliseconds(10))
    static func slow() {}
}
private struct ToolTimeoutModule: ToolModule {
    let definitions: [ActionBinding]
}
@Test(.actionCatalog) func toolDefinitionTimeoutOverridesRuntimeDefaultAndRejectsInvalidDefinition() async throws {
    let definition = ActionBinding(
        function: ToolTimeoutFixture.slowDefinition(handler: { _ in
            try await Task.sleep(for: .seconds(60))
        }), protocols: [.tool], executionPolicy: .direct)
    #expect(definition.timeout == .milliseconds(10))
    let registry = try ToolRegistry(modules: [ToolTimeoutModule(definitions: [definition])])
    let result = try #require(
        try await ToolExecutor(registry: registry).execute(
            ToolRequest(id: UUID().uuidString, toolPath: "Fixture.Control.slow"),
            context: ActionExecutionContext(
                source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString,
                sequence: 1)))
    #expect(result.isError && result.value.contains("timed out"))
    #expect(throws: ToolRegistrationError.invalidDefinition("Fixture.Control.bad")) {
        try ToolRegistry(modules: [
            ToolTimeoutModule(definitions: [
                ActionBinding(path: "Fixture.Control.bad", timeout: .zero, completing: { _ in })
            ])
        ])
    }
}

@Test(.actionCatalog) func toolFailureCapturesProducerDescriptionWithoutDeviceClassification() async throws {
    struct FixtureFailure: LocalizedError { var errorDescription: String? { String(repeating: "业务资源异常", count: 200) } }
    let registry = ToolRegistry()
    try await registry.registerCompletion("Fixture.Control.failure") { _ in throw FixtureFailure() }
    let result = try #require(
        try await ToolExecutor(registry: registry).execute(
            ToolRequest(id: UUID().uuidString, toolPath: "Fixture.Control.failure"),
            context: ActionExecutionContext(
                source: "Fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString,
                sequence: 1)))
    #expect(result.isError)
    #expect(result.value.count == 512)
    #expect(result.value.hasPrefix("业务资源异常"))
}

@Test(.actionCatalog) func toolProducerCodesPreserveAdmissionAndArgumentSemantics() async throws {
    let registry = ToolRegistry()
    try await registry.registerCompletion("Fixture.Control.argument") { _ in
        _ = try ActionArguments([:]).requiredInt("count", range: 1...3)
    }
    try await registry.registerCompletion("Fixture.Control.background") { _ in
        throw ActionExecutionFailure(code: .init(rawValue: "background"), message: "App must be foreground")
    }
    let context = ActionExecutionContext(
        source: "Fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString)
    for (path, code) in [
        ("Fixture.Control.argument", "invalidArguments"), ("Fixture.Control.background", "background"),
        ("Fixture.Control.unknown", "unknownTool"),
    ] {
        let call = ToolRequest(id: UUID().uuidString, toolPath: path)
        let response = try #require(try await ToolExecutor(registry: registry).execute(call, context: context))
        #expect(response.callID == call.id)
        #expect(response.isError && response.failureCode?.rawValue == code)
        #expect(response.deliveryFailure == nil)
    }
    let response = try #require(
        try await ToolExecutor(registry: registry).execute(
            ToolRequest(id: UUID().uuidString, toolPath: "Fixture.Control.background"), context: context))
    #expect(response.value == "App must be foreground")
    let delivered = ToolResult(
        callID: response.callID, value: response.value, isError: response.isError,
        failureCode: response.failureCode?.rawValue)
    #expect(delivered.failureCode == "background")
}

/// Bounded fixture for testing admission and feedback without model or hardware work.
private actor SignalFeedbackRecorder: Agent {
    nonisolated let descriptor: AgentDescriptor
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    private(set) var inputs: [AgentInput] = []
    private var lifecycle: AgentLifecycle = .registered
    init() throws {
        descriptor = AgentDescriptor(
            id: .assistant, name: "Signal feedback fixture", inputs: [.text, .toolResult], outputs: [.toolCall],
            capabilities: try CapabilityRegistry(internalTools: [InternalTool(path: "System.Runtime.runtimeInfo")]))
    }
    func start() { lifecycle = .running }
    func pause() { lifecycle = .paused }
    func resume() { lifecycle = .running }
    func stop() { lifecycle = .stopped }
    func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: inputs.count)
    }
    func receive(_ input: AgentInput) throws {
        guard lifecycle == .running else { throw HarnessError.notRunning }
        guard inputs.count < 8 else { throw CommunicationError.capacityExceeded }
        inputs.append(input)
    }
}

@Test(.actionCatalog, arguments: [false, true]) func returningToolPreservesCausalityAndRuntimeOrigin(_ fails: Bool)
    async throws
{
    let manager = AgentManager()
    let agent = try SignalFeedbackRecorder()
    let session = UUID().uuidString
    try await manager.register(agent, sessionID: session)
    await agent.start()
    let registry = ToolRegistry()
    try await registry.register("System.Runtime.runtimeInfo") { _ in
        if fails { throw ActionExecutionFailure(code: .init(rawValue: "busy"), message: "Actual failure") }
        return "Actual value"
    }
    let configuration = try AgentConfiguration(
        data: Data(
            #"""
            {"version":7,"id":"assistant","actions":{},"tools":[],"communication":{
            "inputs":[{"contract":"tool.result","version":1,"kind":"toolResult"}],
            "subscriptions":[],"publications":[],"sends":[]}}
            """#.utf8))
    let policy = try CommunicationPolicy(configurations: [configuration])
    let gateway = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, policy: policy),
        tools: registry, policy: policy
    ) { _ in }
    let root = UUID().uuidString
    let payload = InputPayload.text("earlier admitted request")
    // Execution may finish after its original input's admission deadline.
    let parent = AgentInput(
        id: UUID().uuidString,
        sessionID: session, payload: payload,
        metadata: InputMetadata(
            payload: payload, rootID: root, parentID: UUID().uuidString, hops: 2,
            deadline: .now.advanced(by: .seconds(-1))), turn: AgentTurn(id: UUID().uuidString, ordinal: 3))
    let call = ToolCall(id: UUID().uuidString, toolPath: "System.Runtime.runtimeInfo", arguments: [:])
    let envelope = OutputEnvelope(
        source: .assistant, context: parent.context, output: .toolCall(call), sequence: 7, taskScope: parent.taskScope)
    let result = try await gateway.execute(envelope)
    #expect(result.tool?.isError == fails)
    #expect(result.tool?.deliveryFailure == nil)
    let feedback = try #require(await agent.inputs.first)
    #expect(feedback.metadata.origin == .runtime)
    #expect(feedback.metadata.source == "runtime")
    #expect(feedback.metadata.incarnation == nil)
    #expect(feedback.metadata.rootID == root)
    #expect(feedback.metadata.parentID == parent.id)
    #expect(feedback.metadata.hops == 3)
    #expect(feedback.metadata.sequence == 7)
    #expect(!feedback.metadata.expired)
    #expect(feedback.turn == parent.turn)
    #expect(feedback.sessionID == session)
    if case .toolResult(let value) = feedback.payload {
        #expect(value.callID == call.id)
        #expect(value.isError == fails)
        #expect(value.value == (fails ? "Actual failure" : "Actual value"))
    } else {
        Issue.record("Expected actual Tool feedback")
    }
    await gateway.shutdown()
    await manager.stopAll()
}

private actor HeldSignalTool {
    nonisolated let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private(set) var executions = 0
    func execute() async throws -> String {
        executions += 1
        started.continuation.yield(())
        var iterator = release.stream.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
        return "Committed effect"
    }
    func finish() { release.continuation.yield(()) }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func returningToolOwnerStopCancelsWithoutDeliveringToReplacementAgent()
    async throws
{
    let manager = AgentManager()
    let original = try SignalFeedbackRecorder()
    let session = UUID().uuidString
    try await manager.register(original, sessionID: session)
    await original.start()
    let held = HeldSignalTool()
    let registry = ToolRegistry()
    try await registry.register("System.Runtime.runtimeInfo") { _ in try await held.execute() }
    let gateway = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: registry
    ) { _ in }
    let parent = AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("intent"))
    let operation = Task {
        try await gateway.execute(
            OutputEnvelope(
                source: .assistant, context: parent.context,
                output: .toolCall(
                    ToolCall(id: UUID().uuidString, toolPath: "System.Runtime.runtimeInfo", arguments: [:])),
                taskScope: parent.taskScope)
        )
    }
    var started = held.started.stream.makeAsyncIterator()
    _ = try #require(await started.next())
    try await manager.remove(.assistant)
    let replacement = try SignalFeedbackRecorder()
    try await manager.register(replacement, sessionID: session)
    await replacement.start()
    await held.finish()
    let result = try await operation.value
    #expect(result.isCancellationOnly && !result.isError)
    #expect(result.failureCode == .cancelled)
    #expect(result.tool == nil)
    #expect(await replacement.inputs.isEmpty)
    #expect(await held.executions == 1)
    await gateway.shutdown()
    await manager.stopAll()
}

@Test(.actionCatalog) func toolFeedbackHopExhaustionPreservesEffectWithoutReplay() async throws {
    let manager = AgentManager()
    let agent = try SignalFeedbackRecorder()
    let session = UUID().uuidString
    try await manager.register(agent, sessionID: session)
    await agent.start()
    let registry = ToolRegistry()
    let recorder = Recorder()
    try await registry.register("System.Runtime.runtimeInfo") { _ in
        await recorder.act()
        return "Completed once"
    }
    let gateway = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: registry
    ) { _ in }
    let payload = InputPayload.text("intent")
    let parent = AgentInput(
        id: UUID().uuidString,
        sessionID: session, payload: payload,
        metadata: InputMetadata(payload: payload, rootID: UUID().uuidString, hops: 8))
    let result = try await gateway.execute(
        OutputEnvelope(
            source: .assistant, context: parent.context,
            output: .toolCall(
                ToolCall(id: UUID().uuidString, toolPath: "System.Runtime.runtimeInfo", arguments: [:])),
            taskScope: parent.taskScope))
    #expect(result.tool?.value == "Completed once")
    #expect(result.tool?.isError == false)
    #expect(result.tool?.deliveryFailure == String(describing: CommunicationError.hopLimitExceeded))
    #expect(await agent.inputs.isEmpty)
    #expect(await recorder.actions == 1)
    await gateway.shutdown()
    await manager.stopAll()
}

/// Deterministic native consumer for transport tests; independent of Assistant text expansion.
private actor RuntimeToolFixture: Agent {
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    nonisolated let descriptor: AgentDescriptor
    init(id: AgentID = .assistant, extraTools: [InternalTool] = []) throws {
        descriptor = AgentDescriptor(
            id: id, name: "Native fixture", inputs: [.text, .toolResult],
            outputs: [.actionCall, .toolCall, .control],
            capabilities: try CapabilityRegistry(
                internalTools: [
                    InternalTool(path: "UI.Caption.print", required: ["text"]),
                    InternalTool(path: "UI.Caption.beginReplyTurn"),
                ] + extraTools))
    }
    private var lifecycle: AgentLifecycle = .registered
    private var queued = 0
    func start() { lifecycle = .running }
    func pause() { lifecycle = .paused }
    func resume() { lifecycle = .running }
    func stop() { lifecycle = .stopped }
    func status() -> AgentStatus { .init(lifecycle: lifecycle, queuedInputs: queued, processedInputs: 0) }
    func receive(_ input: AgentInput) throws {
        guard queued < 1 else { throw HarnessError.queueFull }
        queued += 1
    }
}

@Test(.actionCatalog, arguments: ["cancel", "mixed", "delivery"])
func interruptedVoiceStateIsCancelledWithoutHidingRealFailures(mode: String) async throws {
    let voiceState = InternalTool(path: "UI.VoiceState.setVoiceState", required: ["state"])
    let manager = AgentManager()
    let agent = try RuntimeToolFixture(id: .speechPerception, extraTools: [voiceState])
    try await manager.register(agent)
    try await manager.start(.speechPerception)
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString,
        payload: .text("interrupted recognition"))
    let registry = ToolRegistry()
    if mode == "delivery" {
        // A cancelled handler plus failed feedback delivery remains a real incident.
        try await agent.pause()
        try await agent.receive(input)
        try await registry.register("UI.VoiceState.setVoiceState") { _ in throw CancellationError() }
    } else {
        try await registry.registerCompletion("UI.VoiceState.setVoiceState") { invocation in
            if invocation.call.parameters["state"] == "listening" { return }
            if mode == "mixed" {
                throw ActionReportedError(
                    try ActionReport(entries: [
                        .init(path: "update", status: .cancelled, code: .cancelled),
                        .init(
                            path: "cleanup", status: .failed, code: .handlerFailed,
                            details: ["failureDescription": "Actual cleanup failure"]),
                    ]))
            }
            throw CancellationError()
        }
    }
    let gateway = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: registry,
        sink: { _ in })
    let call = try voiceState.call(["state": "processing"])
    let outcome = try await gateway.execute(
        OutputEnvelope(
            source: .speechPerception, context: input.context, output: .toolCall(call), taskScope: input.taskScope))
    #expect(outcome.isError == (mode != "cancel"))  // Cancelled evidence is not a runtime incident.
    #expect(outcome.tool?.failureCode == (mode == "mixed" ? .handlerFailed : .cancelled))
    #expect(outcome.isCancellationOnly == (mode == "cancel"))
    let observed = try await gateway.observeFailures()
    var iterator = observed.makeAsyncIterator()
    let snapshot = try #require(await iterator.next())
    #expect(snapshot.records.isEmpty == (mode == "cancel"))
    if mode == "mixed" { #expect(outcome.tool?.value.contains("Actual cleanup failure") == true) }
    if mode == "delivery" {
        #expect(outcome.failureCode == .deliveryFailed && outcome.tool?.deliveryFailure != nil)
    } else {
        let next = try await gateway.execute(
            OutputEnvelope(
                source: .speechPerception, context: input.context,
                output: .toolCall(try voiceState.call(["state": "listening"])), sequence: 2, taskScope: input.taskScope)
        )
        #expect(!next.isError && !next.isCancellationOnly)
    }
    let retained = await gateway.executionResults(source: .speechPerception, inputID: input.id)
    #expect(retained.outputs.first?.tool?.callID == call.id)
    #expect(retained.outputs.first?.tool?.failureCode == (mode == "mixed" ? .handlerFailed : .cancelled))
    await gateway.shutdown()
    await manager.stopAll()
}
