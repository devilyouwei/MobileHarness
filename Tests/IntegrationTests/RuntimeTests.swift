import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import Testing
import ToolRuntime
import Tools

@Test func lifecycleAndBoundedQueue() async throws {
    let agent = try AssistantAgent(capacity: 1, chat: FixedTextChat())
    let input = AgentInput(sessionID: UUID(), payload: .text("hello"))
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

@Test func outputOverflowFailsAgent() async throws {
    let agent = try AssistantAgent(chat: FixedTextChat())
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    for _ in 0..<129 {
        if await agent.status().lifecycle == .failed { break }
        try await agent.receive(AgentInput(sessionID: UUID(), payload: .event("test")))
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await agent.status().lifecycle == .failed)
    await #expect(throws: HarnessError.notRunning) {
        try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("rejected")))
    }
}

@Test func capabilitiesRejectUndeclaredActions() throws {
    let descriptor = try AssistantAgent(chat: FixedTextChat()).descriptor
    #expect(throws: HarnessError.forbiddenFunction) {
        try OutputValidator.validate(.actionCall(expectedActionCall(name: "move")), descriptor: descriptor)
    }
    #expect(throws: HarnessError.forbiddenTool) {
        try OutputValidator.validate(.toolCall(ToolCall(toolPath: "deletePhotos")), descriptor: descriptor)
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

private func textRoutingConfiguration(_ id: String, subscribes: Bool = true) throws -> AgentConfiguration {
    try AgentConfiguration(
        data: JSONSerialization.data(withJSONObject: [
            "version": 5, "id": id, "actions": [String: [String]](), "tools": [],
            "communication": [
                "inputs": [["contract": "user.text", "version": 1, "kind": "text"]],
                "subscriptions": subscribes
                    ? [["contract": "user.text", "topic": "user.text", "source": "user"]] : [],
                "publications": [], "sends": [],
            ],
        ]))
}

@Test func subscriptionRoutingIsolatesUnavailableTargets() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat())
    try await manager.register(agent)
    await #expect(throws: HarnessError.duplicateAgent) { try await manager.register(agent) }
    try await manager.start(.assistant)
    let policy = try CommunicationPolicy(configurations: [
        textRoutingConfiguration("assistant"), textRoutingConfiguration("missing"),
    ])
    let gateway = InputGateway(manager: manager, policy: policy)
    let report = try await gateway.publish(AgentInput(sessionID: UUID(), payload: .text("hello")))
    #expect(report.delivered == [.assistant])
    #expect(Set(report.rejected.keys) == [AgentID(rawValue: "missing")])
    #expect(await agent.status().processedInputs == 1)
    await manager.stopAll()
}

@Test func publicationWithoutPolicyDoesNotFallBackToAssistant() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat())
    try await manager.register(agent)
    try await manager.start(.assistant)
    let gateway = InputGateway(manager: manager)
    let input = AgentInput(sessionID: UUID(), payload: .text("hello"))
    await #expect(throws: CommunicationError.unsupportedContract) { try await gateway.publish(input) }
    #expect(await agent.status().processedInputs == 0)
    let report = try await gateway.send(input, to: .assistant)
    #expect(report.delivered == [.assistant])
    #expect(report.rejected.isEmpty)
    await manager.stopAll()
}

@Test func directedAdmissionBypassesSubscriptionsButEnforcesInputSupport() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat())
    try await manager.register(agent)
    try await manager.start(.assistant)
    let policy = try CommunicationPolicy(configurations: [textRoutingConfiguration("assistant", subscribes: false)])
    let gateway = InputGateway(manager: manager, policy: policy)
    let input = AgentInput(sessionID: UUID(), payload: .text("hello"))
    await #expect(throws: CommunicationError.noRecipients) { try await gateway.publish(input) }
    #expect(await agent.status().processedInputs == 0)
    let report = try await gateway.send(input, to: .assistant)
    #expect(report.delivered == [.assistant])
    #expect(report.rejected.isEmpty)
    let unsupported = AgentInput(sessionID: input.sessionID, payload: .event("not declared"))
    let rejected = try await gateway.send(unsupported, to: .assistant)
    #expect(rejected.delivered.isEmpty)
    #expect(rejected.rejected[.assistant] == String(describing: CommunicationError.unsupportedContract))
    #expect(await agent.status().processedInputs == 1)
    await manager.stopAll()
}

private actor Recorder {
    var outputs: [OutputEnvelope] = []
    var actions = 0
    func record(_ output: OutputEnvelope) { outputs.append(output) }
    func act() { actions += 1 }
}

@Test func toolRoundTripPreservesSessionAndCallID() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat())
    try await manager.register(agent)
    let speechRequests = try await bindSpeechRequests(agent)
    try await manager.start(.assistant)
    let requests = InputGateway(manager: manager)
    let tools = ToolRegistry()
    try await tools.register("runtimeInfo") { _ in "runtime healthy" }
    let recorder = Recorder()
    let actions = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            ActionPath(module: "Speech", function: "speak"): { _ in },
            ActionPath(module: "UI", function: "print"): { _ in },
        ]))
    let responses = OutputGateway(manager: manager, requests: requests, tools: tools, actions: actions) {
        await recorder.record($0)
    }
    let session = UUID()
    let input = AgentInput(sessionID: session, payload: .text("/status"))
    _ = try await requests.send(input, to: .assistant)
    // Tool results now asynchronously admit synthesis before emitting playback.
    var iterator = agent.outputs.makeAsyncIterator()
    let first = try #require(await iterator.next())
    guard case .toolCall(let call) = first.output else {
        Issue.record("Expected tool call")
        return
    }
    #expect(first.inputID == input.id)
    let directResult = try #require(try await ToolExecutor(registry: tools).execute(call, envelope: first))
    #expect(directResult.callID == call.id)
    try await responses.dispatch(first)
    let reply = try #require(await iterator.next())
    #expect(reply.sessionID == session)
    #expect(
        await speechRequests.restored(reply.output)
            == .actionCall(expectedActionCall(name: "say", parameters: ["text": "runtime healthy"])))
    try await responses.dispatch(reply)
    #expect(await recorder.outputs.count == 2)
    await agent.stop()
    await responses.shutdown()
}

@Test func functionDispatchResolvesAgentTagThroughRegisteredPath() async throws {
    let manager = AgentManager()
    try await manager.register(AssistantAgent(chat: FixedTextChat()))
    let requests = InputGateway(manager: manager)
    let recorder = Recorder()
    let missing = OutputGateway(manager: manager, requests: requests, tools: ToolRegistry()) { _ in }
    let input = AgentInput(sessionID: UUID(), payload: .event("test"))
    let envelope = OutputEnvelope(
        source: .assistant, input: input,
        output: .actionCall(expectedActionCall(name: "express", parameters: ["emotion": "smile"])))
    await #expect(throws: (any Error).self) { try await missing.dispatch(envelope) }
    let actions = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            ActionPath(module: "UI", function: "express"): { _ in await recorder.act() }
        ]))
    let responses = OutputGateway(manager: manager, requests: requests, tools: ToolRegistry(), actions: actions) {
        _ in
    }
    try await responses.dispatch(envelope)
    try await responses.dispatch(
        OutputEnvelope(source: .assistant, input: input, output: .control("assistant.finished")))
    #expect(await recorder.actions == 1)
    // The path is not a public tag: callers must use the agent's declared alias.
    await #expect(throws: HarnessError.forbiddenFunction) {
        try await responses.dispatch(
            OutputEnvelope(
                source: .assistant, input: input,
                output: .actionCall(expectedActionCall(name: "Display.express"))))
    }
    await responses.shutdown()
}

@Test func unknownAndFailingToolsReturnCorrelatedErrors() async throws {
    let registry = ToolRegistry()
    let unknown = ToolCall(toolPath: "unknown")
    let input = AgentInput(sessionID: UUID(), payload: .text("tool"))
    let result = try #require(
        try await ToolExecutor(registry: registry).execute(
            unknown, envelope: OutputEnvelope(source: .assistant, input: input, output: .toolCall(unknown))))
    #expect(result.isError && result.callID == unknown.id)
    try await registry.register("broken") { _ in throw HarnessError.notRunning }
    let broken = ToolCall(toolPath: "broken")
    let failure = try #require(
        try await ToolExecutor(registry: registry).execute(
            broken, envelope: OutputEnvelope(source: .assistant, input: input, output: .toolCall(broken))))
    #expect(failure.isError)
}

@Test func completionToolsReturnFailureOutcomesAndPropagateCancellation() async throws {
    let registry = ToolRegistry()
    let input = AgentInput(sessionID: UUID(), payload: .text("tool"))
    let call = ToolCall(toolPath: "UI.showPose")
    let envelope = OutputEnvelope(source: .visionPerception, input: input, output: .toolCall(call))
    try await registry.registerCompletion("UI.showPose") { received, origin in
        #expect(received == call.executionRequest)
        #expect(origin.sessionID == input.sessionID)
        #expect(origin.source == AgentID.visionPerception.rawValue)
    }
    #expect(try await ToolExecutor(registry: registry).execute(call, envelope: envelope) == nil)
    await #expect(throws: ToolRegistryError.duplicateHandler) {
        try await registry.register("UI.showPose") { _ in "unexpected" }
    }
    try await registry.register("value") { _ in "" }
    await #expect(throws: ToolRegistryError.duplicateHandler) {
        try await registry.registerCompletion("value") { _, _ in }
    }
    let value = ToolCall(toolPath: "value")
    let result = try #require(try await ToolExecutor(registry: registry).execute(value, envelope: envelope))
    #expect(result.value.isEmpty)  // Empty data is still a result, unlike Void completion.
    try await registry.registerCompletion("failure") { _, _ in throw HarnessError.notRunning }
    let failed = try #require(
        try await ToolExecutor(registry: registry).execute(ToolCall(toolPath: "failure"), envelope: envelope))
    #expect(failed.isError)
    #expect(failed.value.contains("notRunning"))
    try await registry.registerCompletion("cancel") { _, _ in throw CancellationError() }
    let cancelled = try #require(
        try await ToolExecutor(registry: registry).execute(ToolCall(toolPath: "cancel"), envelope: envelope))
    #expect(cancelled.isError)
}

@Test func gatewayForwardsWaitBoundariesAndRejectsUnbalancedCompletion() async throws {
    let manager = AgentManager()
    try await manager.register(AssistantAgent(chat: FixedTextChat()))
    let recorder = Recorder()
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(definitions: [
            ActionDefinition(
                path: .init(module: "UI", function: "express"), displayName: "Expression",
                kind: .finite, completion: "Acknowledged",
                resolvingResources: { request in
                    if request.parameters["emotion"] == "missing" { throw ResourceError.busy }
                    return []
                }, handler: { _ in await recorder.act() })
        ]))
    let gateway = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: ToolRegistry(), actions: scheduler
    ) { _ in }
    let input = AgentInput(sessionID: UUID(), payload: .text("groups"))
    for _ in 0..<2 {
        try await gateway.dispatch(OutputEnvelope(source: .assistant, input: input, output: .scheduling(.beginWait)))
        try await gateway.dispatch(
            OutputEnvelope(
                source: .assistant, input: input,
                output: .actionCall(expectedActionCall(name: "express", parameters: ["emotion": "smile"]))))
        let rejection = try await gateway.execute(
            OutputEnvelope(
                source: .assistant, input: input,
                output: .rejectedCall(
                    CallRejection(kind: .action, alias: "unknown", reason: .unknownCapability))))
        #expect(rejection.isError)
        try await gateway.dispatch(OutputEnvelope(source: .assistant, input: input, output: .scheduling(.endWait)))
    }
    try await gateway.dispatch(OutputEnvelope(source: .assistant, input: input, output: .control("assistant.finished")))
    #expect(await recorder.actions == 2)
    let malformed = AgentInput(sessionID: UUID(), payload: .text("malformed"))
    try await gateway.dispatch(OutputEnvelope(source: .assistant, input: malformed, output: .scheduling(.beginWait)))
    await #expect(throws: ActionSchedulingError.invalidSchedule) {
        try await gateway.dispatch(
            OutputEnvelope(source: .assistant, input: malformed, output: .control("assistant.finished")))
    }
    await gateway.shutdown()
}

@Test func messageFailureIsRecordedWithoutFailingProducer() async throws {
    let port = AgentMessaging { _, _, _ in throw CommunicationError.scopeClosed }
    let input = AgentInput(sessionID: UUID(), payload: .text("fixture"))
    let report = try await port.publishResult(.transcript("hello", final: true), parent: input)
    #expect(report.failure != nil)
    let history = await port.history.snapshot()
    #expect(history.count == 1)
    #expect(history.first?.inputID == input.id)
    #expect(history.first?.report.failure != nil)
    for _ in 0..<128 {
        _ = try await port.publishResult(.transcript("hello", final: true), parent: input)
    }
    #expect(await port.history.snapshot().count == 128)
    #expect(await port.history.evictedCount == 1)
}

@Test func gatewayAccumulatesCompletionToolFailureAndContinuesOtherOutputs() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat())
    try await manager.register(agent)
    _ = try await bindSpeechRequests(agent)
    try await manager.start(.assistant)
    let registry = ToolRegistry()
    try await registry.registerCompletion("UI.print") { _, _ in throw HarnessError.notRunning }
    try await registry.registerCompletion("UI.beginReplyTurn") { _, _ in }
    let gateway = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: registry, sink: { _ in })
    let input = AgentInput(sessionID: UUID(), payload: .event("fixture"))
    let failedCall = try InternalTool(path: "UI.print", required: ["text"]).call(["text": "hello"])
    let first = try await gateway.execute(
        OutputEnvelope(source: .assistant, input: input, output: .toolCall(failedCall)))
    #expect(first.isError)
    let nextCall = try InternalTool(path: "UI.beginReplyTurn").call([:])
    let second = try await gateway.execute(
        OutputEnvelope(source: .assistant, input: input, output: .toolCall(nextCall)))
    #expect(!second.isError)
    for kind in [CallRejection.Kind.action, .tool] {
        for reason in [GenerationError.unknownCapability, .invalidParameters] {
            let rejected = try await gateway.execute(
                OutputEnvelope(
                    source: .assistant, input: input,
                    output: .rejectedCall(
                        CallRejection(kind: kind, alias: "bad", callID: UUID(), reason: reason))))
            #expect(rejected.isError)
        }
    }
    let historyFailure = try await gateway.execute(
        OutputEnvelope(source: .assistant, input: input, output: .control("assistant.historyError: fixture")))
    #expect(historyFailure.isError)
    let continued = try await gateway.execute(
        OutputEnvelope(source: .assistant, input: input, output: .toolCall(nextCall)))
    #expect(!continued.isError)
    #expect(await gateway.executionResults().outputs.count == 8)
}

@Test func toolDeadlineJoinsCleanupAndExplicitCancellationPropagates() async throws {
    let registry = ToolRegistry()
    let cleanup = Recorder()
    try await registry.registerCompletion("slow") { _, _ in
        do { try await Task.sleep(for: .seconds(60)) } catch {
            await cleanup.act()
            throw error
        }
    }
    let call = ToolRequest(toolPath: "slow")
    let context = ToolExecutionContext(source: "fixture", sessionID: UUID(), inputID: UUID(), sequence: 1)
    let result = try #require(
        try await ToolExecutor(registry: registry, timeout: .milliseconds(10)).execute(
            call, context: context))
    #expect(result.isError)
    #expect(result.value.contains("timed out"))
    #expect(await cleanup.actions == 1)
    let task = Task { try await ToolExecutor(registry: registry).execute(call, context: context) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func toolFeedbackRejectionPreservesSuccessfulExecutionValue() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(capacity: 1, chat: FixedTextChat())
    try await manager.register(agent)
    _ = try await bindSpeechRequests(agent)
    try await manager.start(.assistant)
    try await agent.pause()
    let input = AgentInput(sessionID: UUID(), payload: .text("occupied"))
    try await agent.receive(input)
    let tools = ToolRegistry()
    try await tools.register("UI.print") { _ in "completed value" }
    let gateway = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: tools, sink: { _ in })
    let result = try await gateway.execute(
        OutputEnvelope(
            source: .assistant, input: input,
            output: .toolCall(ToolCall(toolPath: "UI.print", arguments: ["text": "fixture"]))))
    #expect(result.isError)
    #expect(result.tool?.value == "completed value")
    #expect(result.tool?.isError == false)
    #expect(result.failure != nil)
    await agent.stop()
}

private enum ToolTimeoutFixture {
    @Tool(path: "Fixture.slow", title: "Slow fixture", timeout: .milliseconds(10))
    static func slow() {}
}
private struct ToolTimeoutModule: ToolModule {
    let definitions: [ToolDefinition]
}
@Test func toolDefinitionTimeoutOverridesRuntimeDefaultAndRejectsInvalidDefinition() async throws {
    let definition = ToolTimeoutFixture.slowDefinition(completing: { _, _ in
        try await Task.sleep(for: .seconds(60))
    })
    #expect(definition.timeout == .milliseconds(10))
    let registry = try ToolRegistry(modules: [ToolTimeoutModule(definitions: [definition])])
    let result = try #require(
        try await ToolExecutor(registry: registry).execute(
            ToolRequest(toolPath: "Fixture.slow"),
            context: ToolExecutionContext(source: "fixture", sessionID: UUID(), inputID: UUID(), sequence: 1)))
    #expect(result.isError && result.value.contains("timed out"))
    #expect(throws: ToolRegistrationError.invalidDefinition("Fixture.bad")) {
        try ToolRegistry(modules: [
            ToolTimeoutModule(definitions: [
                ToolDefinition(path: "Fixture.bad", timeout: .zero, completing: { _, _ in })
            ])
        ])
    }
}
