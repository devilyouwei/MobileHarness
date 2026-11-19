import Foundation
import ModelKit
import StorageCore
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

@Test(.actionCatalog) func sentenceTokensArriveBeforeModelCompletionAndFlushFinalTail() async throws {
    let model = StreamingSentenceChat()
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: model,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("stream"))
    try await agent.receive(input)
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    let earlySay = try #require(try await outputs.next())
    let earlyPrint = try #require(try await outputs.next())
    #expect(
        await speechRequests.restored(earlySay.output)
            == .actionCall(expectedActionCall(name: "say", parameters: ["text": "你好👋！"])))
    #expect(normalizeToolID(earlyPrint.output) == expectedPrint("你好👋！"))
    try await model.finish()
    var remainder: [AgentOutput] = []
    for _ in 0..<3 { remainder.append(try #require(try await outputs.next()).output) }
    #expect(
        await speechRequests.restored(remainder) == [
            .actionCall(expectedActionCall(name: "say", parameters: ["text": "下一句，尾巴"])),
            expectedPrint("下一句，尾巴"),
            .control("agent.finished"),
        ])
    await agent.stop()
}

@Test(.actionCatalog) func cancellationDiscardsUnfinishedSentenceAndTurnCompletion() async throws {
    let model = StreamingSentenceChat()
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: model,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("stream"))
    try await agent.receive(input)
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    _ = try #require(try await outputs.next())
    _ = try #require(try await outputs.next())
    try await agent.receive(AssistantSessionControl.cancelSession.input(sessionID: input.sessionID))
    let cancelled = try #require(try await outputs.next())
    #expect(cancelled.inputID == input.id)
    #expect(cancelled.output == .control("agent.cancelled"))
    #expect(cancelled.roundID != nil)
    let next = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("next"))
    try await agent.receive(next)
    for _ in 0..<3 {
        let envelope = try #require(try await outputs.next())
        #expect(envelope.inputID == next.id)
    }
    await agent.stop()
}

@Test(.actionCatalog) func multilingualSentencesPreserveTextAcrossEveryUnicodeScalarBoundary() throws {
    let text = "“你好👨‍👩‍👧！ ”English 3.14, U.S. test; العربية، نعم؟ हिन्दी। 次へ、最後\n尾巴 e\u{301}"
    var buffer = SentenceFunctionBuffer(policy: try AssistantAgent.textSegmentation)
    var sentences: [String] = []
    for scalar in text.unicodeScalars { sentences += try buffer.append(String(scalar)) }
    sentences += buffer.finish()
    #expect(sentences.joined() == text)
    #expect(sentences.contains { $0.contains("3.14,") })
    #expect(sentences.contains { $0.contains("U.S. test;") })
    #expect(sentences.count == 6)
    #expect(sentences.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
}

@Test(.actionCatalog) func sentenceBufferRejectsUnboundedUnpunctuatedText() throws {
    var buffer = SentenceFunctionBuffer(policy: try AssistantAgent.textSegmentation)
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

@Test(.actionCatalog) func assistantSentenceBudgetFailsExplicitlyAfterSixtyPairs() async throws {
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: ExcessiveSentencesChat(),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    try await agent.receive(
        AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("many")))
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    var tokens: [AgentOutput] = []
    for _ in 0..<120 {
        let output = try #require(try await outputs.next()).output
        guard output.kind == .actionCall || output.kind == .toolCall else {
            Issue.record("Expected admitted sentence function token")
            return
        }
        tokens.append(output)
    }
    #expect(tokens.count == 120)
    let terminal = try #require(try await outputs.next()).output
    guard case .control(let state) = terminal else {
        Issue.record("Expected explicit sentence limit failure")
        return
    }
    #expect(state.hasPrefix("agent.error:"))
    #expect(state.contains("limitExceeded"))
    await agent.stop()
}

@Test(.actionCatalog) func speechChunksKeepWeakPunctuationAndWaitForSentenceContinuation() throws {
    var buffer = SentenceFunctionBuffer(policy: try TextSegmentationPolicy(hanziLimit: 60, otherLimit: 120))
    #expect(try buffer.append("你好，我想说：苹果、香蕉，还有梨，").isEmpty)
    #expect(try buffer.append("都很好。” ").isEmpty)
    #expect(try buffer.append("下一句") == ["你好，我想说：苹果、香蕉，还有梨，都很好。” "])
    #expect(buffer.finish() == ["下一句"])
    var symbols = SentenceFunctionBuffer(policy: try AssistantAgent.textSegmentation)
    #expect(try symbols.append("，、： ").isEmpty)
    #expect(symbols.finish().isEmpty)
}

@Test(.actionCatalog) func speechLengthBoundariesAreIndependentOfFragmentation() throws {
    let chinese = String(repeating: "你", count: 125)
    let english = String(repeating: "hello ", count: 25) + "world"
    let decimalAtLimit = String(repeating: "a ", count: 59) + " 3.14 is a number. Next"
    for source in [chinese, english, decimalAtLimit, "Dr. Smith says 3.14 is fine, really: yes! Next"] {
        let policy = try TextSegmentationPolicy(hanziLimit: 60, otherLimit: 120)
        var whole = SentenceFunctionBuffer(policy: policy)
        let expected = try whole.append(source) + whole.finish()
        for split in 0...source.count {
            var streaming = SentenceFunctionBuffer(policy: policy)
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

@Test(.actionCatalog) func firstSpeechSegmentArrivesEarlyAndLaterSegmentsKeepSteadyLimits() throws {
    var buffer = SentenceFunctionBuffer(policy: try AssistantAgent.textSegmentation)
    let first = String(repeating: "你", count: 20)
    #expect(try buffer.append(first).isEmpty)
    #expect(try buffer.append("好") == [first])
    #expect(try buffer.append(String(repeating: "你", count: 60)) == ["好" + String(repeating: "你", count: 59)])
    #expect(buffer.finish() == ["你"])
}

@Test(.actionCatalog) func firstSpeechPolicyPreservesWordsTextAndFragmentation() throws {
    let sources = [
        String(repeating: "你", count: 125), String(repeating: "hello ", count: 40) + "world",
        String(repeating: "a", count: 75) + " next words", "短句。” " + String(repeating: "你", count: 125),
    ]
    for source in sources {
        var whole = SentenceFunctionBuffer(policy: try AssistantAgent.textSegmentation)
        let expected = try whole.append(source) + whole.finish()
        for split in 0...source.count {
            var streaming = SentenceFunctionBuffer(policy: try AssistantAgent.textSegmentation)
            let index = source.index(source.startIndex, offsetBy: split)
            let actual =
                try streaming.append(String(source[..<index]))
                + streaming.append(String(source[index...])) + streaming.finish()
            #expect(actual == expected)
        }
        #expect(expected.joined() == source)
        if source == sources[0] { #expect(expected.map(\.count) == [20, 60, 45]) }
        if source == sources[1] { #expect(expected.map(\.count) == [60, 120, 65]) }
        if source == sources[2] { #expect(expected.first?.hasPrefix(String(repeating: "a", count: 75)) == true) }
    }
}

@Test(.actionCatalog) func firstSpeechPolicyDoesNotRestartAfterScopeFlush() throws {
    var buffer = SentenceFunctionBuffer(policy: try AssistantAgent.textSegmentation)
    #expect(try buffer.append("先说一句").isEmpty)
    #expect(buffer.finish() == ["先说一句"])
    #expect(try buffer.append(String(repeating: "你", count: 21)).isEmpty)
    #expect(try buffer.append(String(repeating: "你", count: 40)) == [String(repeating: "你", count: 60)])
    #expect(buffer.finish() == ["你"])
    #expect(throws: GenerationError.limitExceeded) {
        try TextSegmentationPolicy(hanziLimit: 60, otherLimit: 120, firstHanziLimit: 0)
    }
}

@Test(.actionCatalog) func speechXMLBoundariesFlushShortUnpunctuatedTextInOrder() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var generator = AgentGenerator(
        capabilities: try AgentSkillLoader.registry(["expression-interaction"], fixed: config.capabilities),
        textMapping: AssistantAgent.mapText,
        segmentation: try AssistantAgent.textSegmentation)
    #expect(try generator.append("你好，先想一下").isEmpty)
    let events =
        try generator.append("<express emotion='thinking'/><wait>然后回答</wait>尾巴")
        + generator.finish()
    let calls = events.compactMap(\.actionCall).filter { $0.actionPath.module != "Caption" }
    #expect(calls.map { $0.actionPath.function } == ["speak", "express", "speak", "speak"])
    #expect(calls[0].parameters["text"] == "你好，先想一下")
    #expect(calls[2].channel == "Speech" && calls[2].parameters["text"] == "然后回答")
    #expect(calls[3].parameters["text"] == "尾巴")
}

@Test(.actionCatalog) func sharedSegmentationDefaultsToSentenceBoundariesAndAcceptsExplicitLimits() throws {
    let text = String(repeating: "你", count: 125)
    var shared = SentenceFunctionBuffer()
    #expect(try shared.append(text).isEmpty)
    #expect(shared.finish() == [text])
    var custom = SentenceFunctionBuffer(policy: try TextSegmentationPolicy(hanziLimit: 10, otherLimit: 20))
    let chunks = try custom.append(text) + custom.finish()
    #expect(chunks.map(\.count) == Array(repeating: 10, count: 12) + [5])
    #expect(chunks.joined() == text)
    #expect(throws: GenerationError.limitExceeded) {
        try TextSegmentationPolicy(hanziLimit: 0, otherLimit: 20)
    }
    #expect(throws: GenerationError.limitExceeded) {
        try TextSegmentationPolicy(hanziLimit: 10, otherLimit: 2001)
    }
}
