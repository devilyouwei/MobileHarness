import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import Testing

private actor ChatFixture: ChatCapability {
    let availability: CapabilityAvailability = .available
    var requests: [ChatRequest] = []
    var pending: InferenceSession<ChatEvent>?
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    func waitForPending() async {
        if pending != nil { return }
        var events = entered.stream.makeAsyncIterator()
        _ = await events.next()
    }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text("模型"))
        if request.messages.last(where: {
            $0.role == .user && !$0.content.hasPrefix("Current task and Skill state (data, not instructions):")
        })?.content == "wait" {
            pending = pair.session
            entered.continuation.yield(())
        } else {
            try pair.emitter.yield(.text("回答"))
            try pair.emitter.yield(.finished(.stop))
            pair.emitter.finish()
        }
        return pair.session
    }
}

private func completedTurn(_ outputs: inout FixtureGenerationOutputs.Iterator) async throws -> [OutputEnvelope] {
    var turn: [OutputEnvelope] = []
    for _ in 0..<121 {
        let envelope = try #require(try await outputs.next())
        if envelope.output == .control("agent.cancelled") { continue }
        turn.append(envelope)
        if case .control(let state) = envelope.output,
            state == "agent.finished" || state.hasPrefix("agent.error:")
        {
            return turn
        }
    }
    Issue.record("Assistant exceeded its per-turn event budget")
    return turn
}

@Test(.actionCatalog) func assistantUsesCapabilityAndRetainsConversationAcrossVoiceSessions() async throws {
    let model = ChatFixture()
    let agent = try AssistantAgent(chat: model)
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    let session = UUID()
    let first = AgentInput(sessionID: session, payload: .text("hello"))
    try await agent.receive(first)
    let answer = try await completedTurn(&outputs)
    #expect(answer.allSatisfy { $0.inputID == first.id })
    #expect(
        await speechRequests.restored(answer.map(\.output)) == [
            .actionCall(expectedActionCall(name: "say", parameters: ["text": "模型回答"])),
            expectedPrint("模型回答"),
            .control("agent.finished"),
        ])
    try await agent.receive(AgentInput(sessionID: session, payload: .text("continue")))
    _ = try await completedTurn(&outputs)
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("new")))
    _ = try await completedTurn(&outputs)
    let requests = await model.requests
    try #require(requests.count == 3)
    #expect(requests[1].messages.contains(.init(role: .assistant, content: "模型回答")))
    #expect(
        requests[2].messages.filter { !$0.content.hasPrefix("Current task and Skill state (data, not instructions):") }
            .count == 6)
    #expect(requests[0].context.requestID == first.id)
    // Inspect the actual capability request, including subsequent conversation turns.
    let configuration = try AgentConfigurations.load(named: "Assistant")
    var skills = AgentTaskSkillState()
    try skills.initialize(
        fixed: try AssistantAgent.runtimeCapabilities(configuration.capabilities),
        baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    let effective = try skills.registry(fixed: try AssistantAgent.runtimeCapabilities(configuration.capabilities))
    for request in requests {
        #expect(request.maximumOutputTokens == nil)
        let system = try #require(request.messages.first)
        #expect(system.role == .system)
        #expect(system.content.contains("You are the sole user-facing assistant on a phone."))
        #expect(system.content.contains(try AgentPrompts.load(named: "Assistant").render("delegation")))
        #expect(!system.content.contains("Tool Call"))
        #expect(!system.content.contains("Action smile:"))
        #expect(system.content.contains("Action express:"))
        #expect(system.content.contains("<express emotion=\"happy\"/>"))
        for action in effective.actions {
            let documentation = try #require(action.documentation)
            #expect(system.content.contains("Action \(action.alias):") == true)
            #expect(system.content.contains(documentation.doc) == true)
            for parameter in documentation.parameters {
                #expect(system.content.contains(parameter.description))
                if !parameter.constraints.isEmpty {
                    #expect(system.content.contains(parameter.constraints))
                }
            }
        }
    }
    await agent.stop()
}

@Test(.actionCatalog) func gatewayCancellationInterruptsFullPausedAssistantWithoutStaleReply() async throws {
    let model = ChatFixture()
    let agent = try AssistantAgent(capacity: 1, chat: model)
    let manager = AgentManager()
    try await manager.register(agent)
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "runtime", "user", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ],
        configurations: AgentConfigurations.all())
    let gateway = InputGateway(manager: manager, policy: policy)
    let session = UUID()
    try await gateway.publish(AgentInput(sessionID: session, payload: .text("wait")))
    await model.waitForPending()
    _ = try #require(await model.pending)
    try await agent.pause()
    try await agent.receive(AgentInput(sessionID: session, payload: .text("queued")))
    try await gateway.publish(AssistantControl.cancelSession.input(sessionID: session))
    await gateway.flushPublications()
    #expect(await agent.status().queuedInputs == 0)
    try await agent.resume()
    let next = AgentInput(sessionID: UUID(), payload: .text("next"))
    try await agent.receive(next)
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    var cancelled: [OutputEnvelope] = []
    var turn: [OutputEnvelope] = []
    while let output = try await outputs.next() {
        if output.output == .control("agent.cancelled") { cancelled.append(output) }
        if output.inputID == next.id { turn.append(output) }
        if output.inputID == next.id, output.output == .control("agent.finished") { break }
    }
    #expect(cancelled.count == 2)
    #expect(cancelled.allSatisfy { $0.sessionID == session })
    #expect(turn.last?.output == .control("agent.finished"))
    #expect(turn.allSatisfy { $0.inputID == next.id })
    await agent.stop()
}

private actor MalformedChatFixture: ChatCapability {
    let availability: CapabilityAvailability = .available
    let malformed: String
    var requests: [ChatRequest] = []

    init(_ malformed: String) { self.malformed = malformed }

    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if requests.count == 1 {
            // Emit a valid prefix before the malformed fragment to exercise partial output.
            try pair.emitter.yield(.text("Before error."))
            try pair.emitter.yield(.text(malformed))
            try pair.emitter.yield(.finished(.stop))
            pair.emitter.finish()
        } else {
            try pair.emitter.yield(.text("Recovered."))
            try pair.emitter.yield(.finished(.stop))
            pair.emitter.finish()
        }
        return pair.session
    }
}

@Test(
    .actionCatalog,
    .timeLimit(.minutes(1)),
    arguments: [
        "<express></express>", "<channel.main>unfinished", "&bogus;",
    ])
func assistantInvalidOutputTerminatesWithoutRetryAndAcceptsNextTurn(_ malformed: String) async throws {
    let model = MalformedChatFixture(malformed)
    let agent = try AssistantAgent(chat: model)
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    let sessionID = UUID()
    let failed = AgentInput(sessionID: sessionID, payload: .text("bad turn"))
    try await agent.receive(failed)
    var rejected: [OutputEnvelope] = []
    while let output = try await outputs.next() {
        rejected.append(output)
        if case .control(let value) = output.output, value.hasPrefix("agent.error:") { break }
    }
    #expect(rejected.allSatisfy { $0.inputID == failed.id })
    #expect(await model.requests.count == 1)
    #expect(await agent.status().lifecycle == .running)
    let next = AgentInput(sessionID: sessionID, payload: .text("try again"))
    try await agent.receive(next)
    let recovered = try await completedTurn(&outputs)
    #expect(recovered.allSatisfy { $0.inputID == next.id })
    #expect(
        (await speechRequests.restored(recovered.map(\.output))).contains {
            $0 == .actionCall(expectedActionCall(name: "say", parameters: ["text": "Recovered."]))
        })
    let requests = await model.requests
    try #require(requests.count == 2)
    #expect(requests[1].messages.contains { $0.role == .user && $0.content == "try again" })
    await agent.stop()
}

private struct LongReplyChat: ChatCapability {
    var availability: CapabilityAvailability { .available }
    static let fragment = String(repeating: "word ", count: 14) + ". "
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        #expect(request.maximumOutputTokens == nil)
        let pair = InferenceSession<ChatEvent>.make(
            limits: try StreamLimits(capacity: 64), estimatedBytes: { $0.estimatedBytes })
        for _ in 0..<40 { try pair.emitter.yield(.text(Self.fragment)) }
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func assistantAcceptsStreamingReplyBeyondFormerWholeReplyLimit()
    async throws
{
    let agent = try AssistantAgent(chat: LongReplyChat())
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("A longer reply")))
    var captions = ""
    for try await envelope in FixtureGenerationOutputs(agent: agent) {
        switch envelope.output {
        case .actionCall(let call) where call.actionPath.description == "UI.Caption.print":
            captions += call.parameters["text"] ?? ""
        case .control(let message):
            #expect(message == "agent.finished")
            await agent.stop()
        default: break
        }
    }
    #expect(captions.utf8.count > 2000)
    #expect(captions == String(repeating: LongReplyChat.fragment, count: 40))
}

@Test(.actionCatalog, arguments: ["<unknown/>", "<express/>"])
func assistantCompletesTurnAfterRejectedAction(_ markup: String) async throws {
    let agent = try AssistantAgent(chat: MalformedChatFixture(markup))
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    var iterator = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("fixture")))
    let outputs = try await completedTurn(&iterator)
    #expect(outputs.contains { if case .rejectedCall = $0.output { true } else { false } })
    #expect(outputs.last?.output == .control("agent.finished"))
    await agent.stop()
}

private actor RejectedToolChatFixture: ChatCapability {
    let availability: CapabilityAvailability = .available
    let name: String
    let arguments: String
    let emitsText: Bool
    private var requests = 0
    init(name: String, arguments: String, emitsText: Bool = true) {
        self.name = name
        self.arguments = arguments
        self.emitsText = emitsText
    }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests += 1
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if requests == 1 {
            try pair.emitter.yield(.toolCall(ChatToolCall(id: "fixture", name: name, argumentsJSON: arguments)))
        }
        if emitsText { try pair.emitter.yield(.text("Continued.")) }
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func rejectedNativeOutcomeWriteFailureTerminatesBeforeOutput()
    async throws
{
    let repository = AgentContextRepository(
        agent: .assistant, scope: UUID(), state: AssistantContextState(),
        persistence: .init(
            load: { nil },
            commit: { context, _ in
                if context.state.history.current.turns.flatMap({ $0.toolCalls ?? [] }).contains(where: {
                    $0.state == .failed
                }) {
                    throw CommunicationError.invalidPayload
                }
            }))
    let agent = try AssistantAgent(
        chat: RejectedToolChatFixture(name: "unknown", arguments: "{}", emitsText: false), context: repository)
    try await agent.start()
    var iterator = agent.outputs.makeAsyncIterator()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("fixture")))
    var outputs: [AgentOutput] = []
    while let output = await iterator.next() {
        outputs.append(output.output)
        if case .control(let message) = output.output, message.hasPrefix("agent.error:") { break }
    }
    #expect(
        outputs.contains { if case .control(let message) = $0 { message.hasPrefix("agent.error:") } else { false } }
    )
    #expect(!outputs.contains { if case .rejectedCall = $0 { true } else { false } })
    #expect(!outputs.contains { if case .toolCall = $0 { true } else { false } })
    #expect(try await repository.snapshot().state.history.current.turns.last?.state == .failed)
    await agent.stop()
}

@Test(.actionCatalog, arguments: ["{}", "{invalid"])
func assistantContinuesAfterRejectedNativeTool(_ arguments: String) async throws {
    let agent = try AssistantAgent(chat: RejectedToolChatFixture(name: "unknown", arguments: arguments))
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    var iterator = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("fixture")))
    let outputs = try await completedTurn(&iterator)
    let rejected = outputs.compactMap { envelope -> CallRejection? in
        if case .rejectedCall(let value) = envelope.output { value } else { nil }
    }
    #expect(rejected.count == 1)
    #expect(rejected.first?.kind == .tool)
    #expect(rejected.first?.callID != nil)
    #expect(outputs.last?.output == .control("agent.finished"))
    await agent.stop()
}

@Test(.actionCatalog) func assistantControlCancellationPreservesOtherSessionWork() async throws {
    let agent = try AssistantAgent(capacity: 2, chat: ChatFixture())
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    try await agent.pause()
    let cancelledSession = UUID()
    let retained = AgentInput(sessionID: UUID(), payload: .text("next"))
    try await agent.receive(AgentInput(sessionID: cancelledSession, payload: .text("discard")))
    try await agent.receive(retained)
    try await agent.receive(AssistantControl.cancelSession.input(sessionID: cancelledSession))
    #expect(await agent.status().queuedInputs == 1)
    #expect(await agent.status().processedInputs == 0)
    try await agent.resume()
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    let turn = try await completedTurn(&outputs)
    #expect(turn.allSatisfy { $0.inputID == retained.id })
    await agent.stop()
}

@Test(.actionCatalog, arguments: ["legacy", "foreign", "user", "agent", "runtime", "incarnation", "expired"])
func invalidAssistantControlCannotCancelQueuedWork(_ kind: String) async throws {
    let agent = try AssistantAgent(capacity: 1, chat: ChatFixture())
    try await agent.start()
    try await agent.pause()
    let session = UUID()
    try await agent.receive(AgentInput(sessionID: session, payload: .text("retained")))
    let valid = AssistantControl.cancelSession.input(sessionID: session)
    let payload: InputPayload
    if kind == "legacy" {
        payload = .event("assistant.cancel")
    } else if kind == "foreign" {
        payload = .observation(
            AgentMessage(contract: AssistantControl.contract, content: "cancelSession", validate: { _ in }))
    } else {
        payload = valid.payload
    }
    let metadata = InputMetadata(
        payload: payload, source: kind == "user" ? "user" : "runtime",
        incarnation: kind == "incarnation" || kind == "agent" ? UUID() : nil,
        origin: kind == "agent" ? .agent : (kind == "runtime" ? .runtime : .external),
        deadline: kind == "expired" ? .now.advanced(by: .seconds(-1)) : nil)
    await #expect(throws: (any Error).self) {
        try await agent.receive(AgentInput(sessionID: session, payload: payload, metadata: metadata))
    }
    #expect(await agent.status().queuedInputs == 1)
    #expect(await agent.status().lifecycle == .paused)
    await agent.stop()
}

@Test(.actionCatalog) func assistantControlSchemaAndGatewayRejectForeignContentAndLegacyContract() async throws {
    let configuration = try AgentConfigurations.load(named: "Assistant")
    let contracts = try AgentContracts.communication
    #expect(!configuration.communication.inputs.contains { $0.contract == "runtime.event" })
    let control = AssistantControl.cancelSession.input(sessionID: UUID())
    #expect(control.metadata.origin == .external)
    #expect(control.metadata.rootID == control.id)
    #expect(control.metadata.parentID == nil)
    guard case .observation(let message) = control.payload else {
        Issue.record("Expected typed control")
        return
    }
    #expect(try contracts.validatedSize(message) <= 512)
    #expect(try JSONDecoder().decode(AssistantControl.self, from: message.encodedContent()) == .cancelSession)
    let foreign = AgentMessage(contract: AssistantControl.contract, content: "cancelSession", validate: { _ in })
    #expect(throws: CommunicationError.invalidPayload) { try contracts.validatedSize(foreign) }
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: ChatFixture())
    try await manager.register(agent)
    try await agent.start()
    try await agent.pause()
    try await agent.receive(AgentInput(sessionID: control.sessionID, payload: .text("retained")))
    let policy = try CommunicationPolicy(
        contracts: contracts,
        externalSources: [
            "runtime", "user", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ],
        configurations: AgentConfigurations.all())
    let gateway = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    await #expect(throws: CommunicationError.invalidPayload) {
        try await gateway.send(
            AgentInput(sessionID: control.sessionID, payload: .observation(foreign)), to: .assistant)
    }
    let legacy = try await gateway.send(
        AgentInput(sessionID: control.sessionID, payload: .event("assistant.cancel")), to: .assistant)
    #expect(legacy.delivered.isEmpty)
    #expect(!legacy.rejected.isEmpty)
    #expect(await agent.status().queuedInputs == 1)
    let accepted = try await gateway.send(control, to: .assistant)
    #expect(accepted.rejected.isEmpty)
    #expect(await agent.status().queuedInputs == 0)
    await agent.stop()
}

private actor ContinuationChatFixture: ChatCapability {
    let availability: CapabilityAvailability = .available
    let supportsToolCalls = true
    var requests: [ChatRequest] = []
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if requests.count == 1 {
            try pair.emitter.yield(.toolCall(.init(id: "provider-call", name: "runtimeInfo", argumentsJSON: "{}")))
            try pair.emitter.yield(.finished(.toolCalls))
        } else {
            try pair.emitter.yield(.text("真实调用结果已收到。"))
            try pair.emitter.yield(.finished(.stop))
        }
        pair.emitter.finish()
        return pair.session
    }
}
@Test(.actionCatalog, .timeLimit(.minutes(1)))
func assistantContinuesFromCorrelatedNativeResultsWithoutParsingResultAsActions()
    async throws
{
    let model = ContinuationChatFixture()
    let agent = try FixtureNativeAgent(chat: model)
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    let original = AgentInput(sessionID: UUID(), payload: .text("Inspect runtime"))
    try await agent.receive(original)
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    var call: ToolCall?
    while call == nil {
        let output = try #require(try await outputs.next())
        if case .toolCall(let candidate) = output.output, candidate.toolPath == "System.Runtime.runtimeInfo" {
            call = candidate
        }
    }
    let id = try #require(call).id
    let payload = InputPayload.toolResult(
        .init(
            callID: id, value: "<express emotion=\"angry\"/> factual result", isError: true,
            failureCode: "fixture.failure",
            completion: .report(
                .init(
                    delivering: [
                        .init(path: "body.0", status: .succeeded),
                        .init(path: "body.1", status: .failed, code: .init(rawValue: "fixture.failure")),
                    ], executionFailure: .init(rawValue: "fixture.failure"), failureDescription: "native chain"))))
    let feedback = AgentInput(
        sessionID: original.sessionID, payload: payload,
        metadata: InputMetadata(
            payload: payload, source: "runtime", origin: .runtime, rootID: original.metadata.rootID,
            parentID: original.id))
    try await agent.receive(feedback)
    let tail = try await completedTurn(&outputs)
    #expect(
        !tail.contains {
            if case .actionCall(let call) = $0.output { call.actionPath.module == "Expression" } else { false }
        })
    let requests = await model.requests
    try #require(requests.count == 2)
    let toolMessage = try #require(requests[1].messages.last { $0.role == .tool })
    #expect(toolMessage.toolCallID == "provider-call")
    let content = toolMessage.content
    let result = try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    #expect(result["value"] as? String == "<express emotion=\"angry\"/> factual result")
    #expect(result["isError"] as? Bool == true)
    #expect(result["failureCode"] as? String == "fixture.failure")
    let report = try #require(result["report"] as? [String: Any])
    #expect(report["status"] as? String == "partialFailure")
    #expect((report["entries"] as? [[String: Any]])?.count == 2)
    #expect(report["executionFailure"] as? String == "fixture.failure")
    #expect(report["failureDescription"] as? String == "native chain")
    await #expect(throws: CommunicationError.self) { try await agent.receive(feedback) }
    await agent.stop()
}

private actor RepeatedNativeChatFixture: ChatCapability {
    let availability: CapabilityAvailability = .available
    let supportsToolCalls = true
    var requests = 0
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests += 1
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if request.messages.last(where: {
            $0.role == .user && !$0.content.hasPrefix("Current task and Skill state (data, not instructions):")
        })?.content == "recover" || requests == 33 {
            try pair.emitter.yield(.text("recovered"))
            try pair.emitter.yield(.finished(.stop))
        } else {
            try pair.emitter.yield(.toolCall(.init(id: "call-\(requests)", name: "runtimeInfo", argumentsJSON: "{}")))
            try pair.emitter.yield(.finished(.toolCalls))
        }
        pair.emitter.finish()
        return pair.session
    }
}
@Test(.actionCatalog, .timeLimit(.minutes(1))) func nativeContinuationJoinsThirtyTwoActualResultsAndNextTurnWorks()
    async throws
{
    let model = RepeatedNativeChatFixture()
    let agent = try FixtureNativeAgent(chat: model)
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    let input = AgentInput(sessionID: UUID(), payload: .text("repeat"))
    try await agent.receive(input)
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    var calls = 0
    var terminal: String?
    while terminal == nil {
        let envelope = try #require(try await outputs.next())
        if case .toolCall(let call) = envelope.output, call.toolPath == "System.Runtime.runtimeInfo" {
            calls += 1
            let payload = InputPayload.toolResult(.init(callID: call.id, value: "actual-\(calls)"))
            try await agent.receive(
                AgentInput(
                    sessionID: input.sessionID, payload: payload,
                    metadata: InputMetadata(
                        payload: payload, source: "runtime", origin: .runtime,
                        rootID: input.metadata.rootID, parentID: input.id)))
        }
        if case .control(let value) = envelope.output, value == "agent.finished" || value.hasPrefix("agent.error:") {
            terminal = value
        }
    }
    #expect(calls == 32)
    #expect(await model.requests == 33)
    #expect(terminal == "agent.finished")
    try await agent.receive(AgentInput(sessionID: input.sessionID, payload: .text("recover")))
    _ = try await completedTurn(&outputs)
    #expect(await model.requests == 34)
    await agent.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func hostCancelTerminatesActiveInferenceBeforeQueuedCancellationAndOtherSessionReply() async throws {
    let model = ChatFixture()
    let agent = try AssistantAgent(chat: model)
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    let session = UUID()
    let active = AgentInput(sessionID: session, payload: .text("wait"))
    let queued = AgentInput(sessionID: session, payload: .text("queued"))
    let retained = AgentInput(sessionID: UUID(), payload: .text("next"))
    try await agent.receive(active)
    await model.waitForPending()
    _ = try #require(await model.pending)
    try await agent.receive(queued)
    try await agent.receive(retained)
    try await agent.receive(AgentSessionControl.cancelSession.input(sessionID: session))
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    var cancelled: [OutputEnvelope] = []
    var next: [OutputEnvelope] = []
    for _ in 0..<121 {
        let output = try #require(try await outputs.next())
        if output.output == .control("agent.cancelled") { cancelled.append(output) }
        if output.inputID == retained.id {
            #expect(cancelled.map(\.inputID) == [active.id, queued.id])
            next.append(output)
        }
        if output.inputID == retained.id, output.output == .control("agent.finished") { break }
    }
    #expect(cancelled.map(\.inputID) == [active.id, queued.id])
    #expect(cancelled.first?.roundID != nil)
    #expect(next.last?.output == .control("agent.finished"))
    #expect(await agent.status().lifecycle == .running)
    let fresh = AgentInput(sessionID: session, payload: .text("hello again"))
    try await agent.receive(fresh)
    let recovered = try await completedTurn(&outputs)
    #expect(recovered.allSatisfy { $0.inputID == fresh.id })
    await agent.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func closingSessionCancelsRunningAndWaitingForegroundTasksAndAllowsFreshConversation(_ running: Bool) async throws {
    let session = UUID()
    let original = AgentInput(sessionID: session, payload: .text("wait"))
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var initial = AssistantContextState()
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    _ = try skills.control(
        "startTask", arguments: ["goal": "拍照并等待选择", "skills": "[\"photography\"]"],
        inputID: original.id, fixed: fixed, sessionID: session)
    if !running { try skills.roundCompleted(failed: false, fixed: fixed, inputID: original.id) }
    initial.skillState = skills
    let repository = AgentContextRepository(agent: .assistant, scope: UUID(), state: initial)
    let model = ChatFixture()
    let agent = try AssistantAgent(chat: model, context: repository)
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    if running {
        try await agent.receive(original)
        await model.waitForPending()
        _ = try #require(await model.pending)
    }
    try await agent.receive(AgentSessionControl.cancelSession.input(sessionID: session))
    let state = try #require(try await repository.snapshot().state.skillState)
    #expect(state.activeTaskID == nil)
    #expect(state.tasks.last?.status == "cancelled")
    #expect(state.tasks.last?.failure == nil)
    #expect(!state.loaded.contains("photography"))
    try await agent.receive(.init(sessionID: session, payload: .text("hello again")))
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    while let output = try await outputs.next() {
        #expect(
            {
                if case .control(let value) = output.output { return !value.hasPrefix("agent.error:") }
                return true
            }())
        if output.output == .control("agent.finished") { break }
    }
    await agent.stop()
}
