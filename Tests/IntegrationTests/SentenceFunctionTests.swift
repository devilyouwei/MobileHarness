import Foundation
import ModelKit
import Testing

@testable import AgentCore
@testable import Agents

private actor StreamingSentenceChat: ChatCapability {
    let availability: CapabilityAvailability = .available
    private var emitter: InferenceEmitter<ChatEvent>?
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if request.messages.last?.content == "next" {
            try pair.emitter.yield(.text("新的回答"))
            try pair.emitter.yield(.finished(.stop))
            pair.emitter.finish()
        } else {
            // No completion is emitted until the test explicitly allows it.
            try pair.emitter.yield(.text("你好👋！下一"))
            emitter = pair.emitter
        }
        return pair.session
    }
    func finish() throws {
        let emitter = try #require(emitter)
        try emitter.yield(.text("句，尾巴"))
        try emitter.yield(.finished(.stop))
        emitter.finish()
    }
}

@Test func sentenceTokensArriveBeforeModelCompletionAndFlushFinalTail() async throws {
    let model = StreamingSentenceChat()
    let agent = try AssistantAgent(chat: model)
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    let input = AgentInput(sessionID: UUID(), payload: .text("stream"))
    try await agent.receive(input)
    var outputs = agent.outputs.makeAsyncIterator()
    let earlySay = try #require(await outputs.next())
    let earlyPrint = try #require(await outputs.next())
    #expect(
        await speechRequests.restored(earlySay.output)
            == .actionCall(expectedActionCall(name: "say", parameters: ["text": "你好👋！"])))
    #expect(earlyPrint.output == .actionCall(expectedActionCall(name: "print", parameters: ["text": "你好👋！"])))
    try await model.finish()
    var remainder: [AgentOutput] = []
    for _ in 0..<3 { remainder.append(try #require(await outputs.next()).output) }
    #expect(
        await speechRequests.restored(remainder) == [
            .actionCall(expectedActionCall(name: "say", parameters: ["text": "下一句，尾巴"])),
            .actionCall(expectedActionCall(name: "print", parameters: ["text": "下一句，尾巴"])),
            .control("assistant.finished"),
        ])
    await agent.stop()
}

@Test func cancellationDiscardsUnfinishedSentenceAndTurnCompletion() async throws {
    let model = StreamingSentenceChat()
    let agent = try AssistantAgent(chat: model)
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    let input = AgentInput(sessionID: UUID(), payload: .text("stream"))
    try await agent.receive(input)
    var outputs = agent.outputs.makeAsyncIterator()
    _ = try #require(await outputs.next())
    _ = try #require(await outputs.next())
    try await agent.receive(AgentInput(sessionID: input.sessionID, payload: .event("assistant.cancel")))
    let next = AgentInput(sessionID: UUID(), payload: .text("next"))
    try await agent.receive(next)
    for _ in 0..<3 {
        let envelope = try #require(await outputs.next())
        #expect(envelope.inputID == next.id)
    }
    await agent.stop()
}

@Test func multilingualSentencesPreserveTextAcrossEveryUnicodeScalarBoundary() throws {
    let text = "“你好👨‍👩‍👧！ ”English 3.14, U.S. test; العربية، نعم؟ हिन्दी। 次へ、最後\n尾巴 e\u{301}"
    var buffer = SentenceFunctionBuffer()
    var sentences: [String] = []
    for scalar in text.unicodeScalars { sentences += try buffer.append(String(scalar)) }
    sentences += buffer.finish()
    #expect(sentences.joined() == text)
    #expect(sentences.contains { $0.contains("3.14,") })
    #expect(sentences.contains { $0.contains("U.S. test;") })
    #expect(sentences.count == 6)
    #expect(sentences.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
}

@Test func sentenceBufferRejectsUnboundedUnpunctuatedText() throws {
    var buffer = SentenceFunctionBuffer()
    _ = try buffer.append(String(repeating: "a", count: 2000))
    #expect(throws: GenerationError.limitExceeded) { try buffer.append("b") }
}

private struct ExcessiveSentencesChat: ChatCapability {
    let availability: CapabilityAvailability = .available
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text(String(repeating: "句。", count: 61)))
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}

@Test func assistantSentenceBudgetFailsExplicitlyAfterSixtyPairs() async throws {
    let agent = try AssistantAgent(chat: ExcessiveSentencesChat())
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("many")))
    var outputs = agent.outputs.makeAsyncIterator()
    var tokens: [ActionCall] = []
    for _ in 0..<120 {
        let output = try #require(await outputs.next()).output
        guard case .actionCall(let token) = output else {
            Issue.record("Expected admitted sentence function token")
            return
        }
        tokens.append(token)
    }
    #expect(tokens.count == 120)
    let terminal = try #require(await outputs.next()).output
    guard case .control(let state) = terminal else {
        Issue.record("Expected explicit sentence limit failure")
        return
    }
    #expect(state.hasPrefix("assistant.error:"))
    #expect(state.contains("limitExceeded"))
    await agent.stop()
}

@Test func speechChunksKeepWeakPunctuationAndWaitForSentenceContinuation() throws {
    var buffer = SentenceFunctionBuffer()
    #expect(try buffer.append("你好，我想说：苹果、香蕉，还有梨，").isEmpty)
    #expect(try buffer.append("都很好。” ").isEmpty)
    #expect(try buffer.append("下一句") == ["你好，我想说：苹果、香蕉，还有梨，都很好。” "])
    #expect(buffer.finish() == ["下一句"])
    var symbols = SentenceFunctionBuffer()
    #expect(try symbols.append("，、： ").isEmpty)
    #expect(symbols.finish().isEmpty)
}

@Test func speechLengthBoundariesAreIndependentOfFragmentation() throws {
    let chinese = String(repeating: "你", count: 125)
    let english = String(repeating: "hello ", count: 25) + "world"
    let decimalAtLimit = String(repeating: "a ", count: 59) + " 3.14 is a number. Next"
    for source in [chinese, english, decimalAtLimit, "Dr. Smith says 3.14 is fine, really: yes! Next"] {
        var whole = SentenceFunctionBuffer()
        let expected = try whole.append(source) + whole.finish()
        for split in 0...source.count {
            var streaming = SentenceFunctionBuffer()
            let index = source.index(source.startIndex, offsetBy: split)
            let actual =
                try streaming.append(String(source[..<index]))
                + streaming.append(String(source[index...])) + streaming.finish()
            #expect(actual == expected)
        }
        #expect(expected.joined() == source)
        if source == decimalAtLimit { #expect(expected[0].contains("3.14")) }
        if source == chinese { #expect(expected.map(\.count) == [60, 60, 5]) }
        if source == english {
            #expect(expected.count == 2)
            #expect(expected[0].count == 120)
            #expect(expected[1].hasPrefix("hello"))
        }
    }
}

@Test func speechXMLBoundariesFlushShortUnpunctuatedTextInOrder() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var generator = try AgentGenerator(capabilities: config.capabilities, textActions: ["say", "print"])
    #expect(try generator.append("你好，先想一下").isEmpty)
    let events =
        try generator.append("<express emotion='thinking'/><channel.Speech>然后回答</channel.Speech>尾巴")
        + generator.finish()
    let calls = events.compactMap(\.actionCall)
    #expect(calls.map { $0.actionPath.function } == ["speak", "print", "express", "speak", "print", "speak", "print"])
    #expect(calls[0].parameters["text"] == "你好，先想一下")
    #expect(calls[3].channel == "Speech" && calls[3].parameters["text"] == "然后回答")
    #expect(calls[5].parameters["text"] == "尾巴")
}
