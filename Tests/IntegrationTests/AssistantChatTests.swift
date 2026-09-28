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

private func completedTurn(_ outputs: inout AsyncStream<OutputEnvelope>.Iterator) async throws -> [OutputEnvelope] {
    var turn: [OutputEnvelope] = []
    for _ in 0..<121 {
        let envelope = try #require(await outputs.next())
        turn.append(envelope)
        if envelope.output == .control("assistant.finished") { return turn }
    }
    Issue.record("Assistant exceeded its per-turn event budget")
    return turn
}

@Test func assistantUsesCapabilityAndRetainsConversationAcrossVoiceSessions() async throws {
    let model = ChatFixture()
    let agent = try AssistantAgent(chat: model)
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = agent.outputs.makeAsyncIterator()
    let session = UUID()
    let first = AgentInput(sessionID: session, payload: .text("hello"))
    try await agent.receive(first)
    let answer = try await completedTurn(&outputs)
    #expect(answer.allSatisfy { $0.inputID == first.id })
    #expect(
        await speechRequests.restored(answer.map(\.output)) == [
            .actionCall(expectedActionCall(name: "say", parameters: ["text": "模型回答"])),
            .actionCall(expectedActionCall(name: "print", parameters: ["text": "模型回答"])),
            .control("assistant.finished"),
        ])
    try await agent.receive(AgentInput(sessionID: session, payload: .text("continue")))
    _ = try await completedTurn(&outputs)
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("new")))
    _ = try await completedTurn(&outputs)
    let requests = await model.requests
    #expect(requests.count == 3)
    #expect(requests[1].messages.contains(.init(role: .assistant, content: "模型回答")))
    #expect(requests[2].messages.count == 6)
    #expect(requests[0].context.requestID == first.id)
    // Inspect the actual capability request, including subsequent conversation turns.
    let configuration = try AgentConfigurations.load(named: "Assistant")
    for request in requests {
        #expect(request.maximumOutputTokens == nil)
        let system = try #require(request.messages.first)
        #expect(system.role == .system)
        #expect(
            system.content
                == (try AssistantAgent.systemPrompt(
                    capabilities: configuration.capabilities)))
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
    let gateway = InputGateway(manager: manager)
    let session = UUID()
    _ = try await gateway.send(AgentInput(sessionID: session, payload: .text("wait")), to: .assistant)
    for _ in 0..<10000 {
        if await model.pending != nil { break }
        await Task.yield()
    }
    _ = try #require(await model.pending)
    try await agent.pause()
    try await agent.receive(AgentInput(sessionID: session, payload: .text("queued")))
    let report = try await gateway.send(
        AgentInput(sessionID: session, payload: .event("assistant.cancel")), to: .assistant)
    #expect(report.rejected.isEmpty)
    #expect(await agent.status().queuedInputs == 0)
    try await agent.resume()
    let next = AgentInput(sessionID: UUID(), payload: .text("next"))
    try await agent.receive(next)
    var outputs = agent.outputs.makeAsyncIterator()
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
        "<express></express>", "<channel.main>unfinished", "&bogus;", "<unknown/>",
    ])
func assistantReportsInvalidOutputAndAcceptsNextTurn(_ malformed: String) async throws {
    let model = MalformedChatFixture(malformed)
    let agent = try AssistantAgent(chat: model)
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = agent.outputs.makeAsyncIterator()
    let sessionID = UUID()
    let failed = AgentInput(sessionID: sessionID, payload: .text("bad turn"))
    try await agent.receive(failed)
    var reported = false
    for _ in 0..<121 {
        let output = try #require(await outputs.next())
        #expect(output.inputID == failed.id)
        #expect(output.output != .control("assistant.finished"))
        if case .control(let message) = output.output {
            #expect(message.hasPrefix("assistant.error:"))
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
    #expect(requests.count == 2)
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
    for await envelope in agent.outputs {
        switch envelope.output {
        case .actionCall(let call) where call.actionPath == ActionPath(module: "UI", function: "print"):
            captions += call.parameters["text"] ?? ""
        case .control(let message):
            #expect(message == "assistant.finished")
            await agent.stop()
        default: break
        }
    }
    #expect(captions.utf8.count > 2000)
    #expect(captions == String(repeating: LongReplyChat.fragment, count: 40))
}
