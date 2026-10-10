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
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text("模型"))
        if request.messages.last?.content == "wait" {
            pending = pair.session
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

@Test func assistantUsesCapabilityAndRetainsConversationAcrossVoiceSessions() async throws {
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
    #expect(requests[2].messages.count == 6)
    #expect(requests[0].context.requestID == first.id)
    // Inspect the actual capability request, including subsequent conversation turns.
    let configuration = try AgentConfigurations.load(named: "Assistant")
    for request in requests {
        #expect(request.maximumOutputTokens == nil)
        let system = try #require(request.messages.first)
        #expect(system.role == .system)
        #expect(system.content.contains("You are a voice assistant on a phone."))
        #expect(system.content.contains(AgentCapabilityCatalog.summary))
        #expect(!system.content.contains("Tool Call"))
        for tool in configuration.capabilities.tools {
            #expect(!system.content.contains(tool.alias))
            #expect(!system.content.contains(try #require(tool.definition).function.description))
        }
        #expect(!system.content.contains("Action smile:"))
        #expect(system.content.contains("Action express:"))
        #expect(system.content.contains("<express emotion=\"happy\"/>"))
        for action in configuration.capabilities.actions {
            let documentation = try #require(action.documentation)
            #expect(system.content.contains("Action \(action.alias):") == true)
            #expect(system.content.contains(documentation.doc) == true)
            for example in documentation.examples {
                #expect(system.content.contains("Example: " + example) == true)
            }
            for parameter in documentation.parameters {
                #expect(system.content.contains(parameter.description))
                #expect(system.content.contains(parameter.constraints))
            }
        }
    }
    await agent.stop()
}

@Test func gatewayCancellationInterruptsFullPausedAssistantWithoutStaleReply() async throws {
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
    for _ in 0..<10000 {
        if await model.pending != nil { break }
        await Task.yield()
    }
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
    let cancelledTurn = try await completedTurn(&outputs)
    #expect(
        cancelledTurn.contains {
            if case .control(let value) = $0.output { return value.contains("inference suspended") }
            return false
        })
    let turn = try await completedTurn(&outputs)
    #expect(turn.allSatisfy { $0.inputID == next.id })
    #expect(
        await speechRequests.restored(try #require(turn.first).output)
            == .actionCall(expectedActionCall(name: "say", parameters: ["text": "模型回答"])))
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
    .timeLimit(.minutes(1)),
    arguments: [
        "<express></express>", "<channel.main>unfinished", "&bogus;",
    ])
func assistantReportsInvalidOutputAndAcceptsNextTurn(_ malformed: String) async throws {
    let model = MalformedChatFixture(malformed)
    let agent = try AssistantAgent(chat: model)
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    let sessionID = UUID()
    let failed = AgentInput(sessionID: sessionID, payload: .text("bad turn"))
    try await agent.receive(failed)
    var reported = false
    for _ in 0..<121 {
        let output = try #require(try await outputs.next())
        #expect(output.inputID == failed.id)
        #expect(output.output != .control("agent.finished"))
        if case .control(let message) = output.output {
            #expect(message.hasPrefix("agent.error:"))
            reported = true
            break
        }
    }
    #expect(reported)
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
    #expect(requests[1].messages.count == 2)
    #expect(!requests[1].messages.contains { $0.content == "bad turn" })
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

@Test(.timeLimit(.minutes(1))) func assistantAcceptsStreamingReplyBeyondFormerWholeReplyLimit() async throws {
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

@Test(arguments: ["<unknown/>", "<express/>"])
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

private struct RejectedToolChatFixture: ChatCapability {
    let availability: CapabilityAvailability = .available
    let name: String
    let arguments: String
    var emitsText = true
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.toolCall(ChatToolCall(id: "fixture", name: name, argumentsJSON: arguments)))
        if emitsText { try pair.emitter.yield(.text("Continued.")) }
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}

@Test(.timeLimit(.minutes(1))) func rejectedNativeOutcomeWriteFailureTerminatesBeforeOutput() async throws {
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

@Test(arguments: ["{}", "{invalid"])
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

@Test func assistantControlCancellationPreservesOtherSessionWork() async throws {
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

@Test(arguments: ["legacy", "foreign", "user", "agent", "runtime", "incarnation", "expired"])
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

@Test func assistantControlSchemaAndGatewayRejectForeignContentAndLegacyContract() async throws {
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
@Test(.timeLimit(.minutes(1))) func assistantContinuesFromCorrelatedNativeResultsWithoutParsingResultAsActions()
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
    #expect(requests[1].messages.last?.role == .tool)
    #expect(requests[1].messages.last?.toolCallID == "provider-call")
    let content = try #require(requests[1].messages.last?.content)
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
        if request.messages.last?.content == "recover" {
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
@Test(.timeLimit(.minutes(1))) func nativeContinuationLimitWaitsForActualResultsAndNextTurnRecovers() async throws {
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
        if case .control(let value) = envelope.output, value.hasPrefix("agent.error:") { terminal = value }
    }
    #expect(calls == 4)
    #expect(await model.requests == 4)
    #expect(terminal?.contains("round limit") == true)
    try await agent.receive(AgentInput(sessionID: input.sessionID, payload: .text("recover")))
    _ = try await completedTurn(&outputs)
    #expect(await model.requests == 5)
    await agent.stop()
}
