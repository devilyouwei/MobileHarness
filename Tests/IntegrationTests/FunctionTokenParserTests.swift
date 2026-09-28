import AgentCore
import Agents
import Foundation
import ModelKit
import Testing

private func generator() throws -> AgentGenerator {
    try AgentGenerator(
        capabilities: AgentConfigurations.load(named: "Assistant").capabilities, textActions: ["say", "print"])
}

@Test func functionTokenParserEveryByteSplitPreservesActionsTextAndNestedChannels() throws {
    let source =
        "前👨‍👩‍👧。<channel.main>你好 &amp; 世界<express emotion='smile'/><channel.Display><print text='a&gt;b &quot;引号&quot;'/></channel.Display>再见</channel.main>默认。"
    let data = Data(source.utf8)
    var whole = try generator()
    let expected = try whole.append(data) + whole.finish()
    for split in 0...data.count {
        var parser = try generator()
        let actual = try parser.append(data.prefix(split)) + parser.append(data.dropFirst(split)) + parser.finish()
        #expect(actual == expected, "UTF-8 split \(split)")
    }
    var bytewise = try generator()
    var actual: [ActionCall] = []
    for byte in data { actual += try bytewise.append(Data([byte])) }
    actual += try bytewise.finish()
    #expect(actual == expected)
    #expect(
        expected.map(\.channel) == [
            "Speech", "Display", "main", "main", "main", "Display", "main", "main", "Speech", "Display",
        ])
    #expect(expected[2].parameters["text"] == "你好 & 世界")
    #expect(expected[5].parameters["text"] == "a>b \"引号\"")
}

@Test func functionTokenParserStreamsCompleteActionsWithoutWaitingForChannelClose() throws {
    var parser = try generator()
    #expect(try parser.append("<channel.ma").isEmpty)
    #expect(try parser.append("in><express emotion='smile'").isEmpty)
    let early = try parser.append("/>")
    #expect(early.count == 1)
    #expect(early.first?.channel == "main")
    let next = try parser.append("</channel.main><express emotion='smile'/>")
    #expect(next.first?.channel == "Display")
    #expect(try parser.finish().isEmpty)
}

@Test(arguments: [
    "<express></express>", "</express>", "<channel.main/>", "<channel.main></channel.Display>",
    "</channel.main>", "<!-- comment -->", "<!DOCTYPE x>", "<?xml version='1.0'?>", "<![CDATA[x]]>",
    "<say text='a' text='b'/>", "<say text='a'other='b'/>", "<say text='a<b'/>", "<say text=no/>",
    "&bogus;", "&#+65;", "&#x+41;", "&#0;", "&#xD800;", "\u{0}",
])
func functionTokenParserRejectsMalformedXMLAndNeverReusesFailedParser(_ source: String) throws {
    var parser = FunctionTokenParser()
    #expect(throws: (any Error).self) {
        _ = try parser.append(source)
        _ = try parser.finish()
    }
    #expect(throws: GenerationError.closed) { try parser.append("<express emotion='smile'/>") }
}

@Test(arguments: ["<express", "<say text='unfinished", "&amp", "<channel.main>text"])
func functionTokenParserRejectsTruncatedCompletion(_ source: String) throws {
    var parser = FunctionTokenParser()
    _ = try parser.append(source)
    #expect(throws: GenerationError.incompleteDocument) { try parser.finish() }
}

@Test func parserLimitsAndInvalidUTF8FailExplicitly() throws {
    var invalid = FunctionTokenParser()
    #expect(throws: GenerationError.invalidUTF8) { try invalid.append(Data([0xF0, 0x28])) }
    var partial = FunctionTokenParser()
    _ = try partial.append(Data([0xF0, 0x9F]))
    #expect(throws: GenerationError.incompleteDocument) { try partial.finish() }
    var depth = FunctionTokenParser()
    #expect(throws: GenerationError.limitExceeded) { try depth.append(String(repeating: "<channel.main>", count: 9)) }
    var tag = FunctionTokenParser()
    #expect(throws: GenerationError.limitExceeded) {
        try tag.append("<say text='" + String(repeating: "x", count: 4096))
    }
    var total = FunctionTokenParser()
    #expect(throws: GenerationError.limitExceeded) { try total.append(String(repeating: "x", count: 65537)) }
    var tokens = FunctionTokenParser()
    #expect(throws: GenerationError.limitExceeded) {
        try tokens.append(String(repeating: "<express emotion='smile'/>", count: 1025))
    }
}

@Test func capabilityAliasesAreAgentLocalAndToolsUseSeparateProtocol() throws {
    let camera = try CapabilityRegistry(
        actions: [
            ActionRegistration(
                alias: "say", path: ActionPath(module: "Robot", function: "speak"), defaultChannel: "robot",
                requiredParameters: ["text"])
        ], tools: [ToolRegistration(alias: "lookup", path: "Memory.lookup", requiredParameters: ["query"])])
    var other = try AgentGenerator(capabilities: camera, textActions: ["say"])
    let calls = try other.append("hello") + other.finish()
    #expect(calls.count == 1 && calls[0].actionPath.module == "Robot" && calls[0].channel == "robot")
    let id = UUID()
    let tool = try ToolCallParser.parse(
        id: id, alias: "lookup", argumentsJSON: Data(#"{"query":"x"}"#.utf8), capabilities: camera)
    #expect(tool.id == id && tool.toolPath == "Memory.lookup" && tool.arguments == ["query": "x"])
    #expect(throws: GenerationError.invalidParameters) {
        try ToolCallParser.parse(
            id: id, alias: "lookup", argumentsJSON: Data(#"{"query":4}"#.utf8), capabilities: camera)
    }
    #expect(throws: GenerationError.duplicateAlias) {
        try CapabilityRegistry(actions: camera.actions, tools: [ToolRegistration(alias: "say", path: "Other.say")])
    }
    var xmlTool = try AgentGenerator(capabilities: camera, textActions: ["say"])
    #expect(throws: GenerationError.unknownCapability) { try xmlTool.append("<lookup query='x'/>") }
    var forbidden = try generator()
    #expect(throws: GenerationError.forbiddenChannel) {
        try forbidden.append("<channel.robot><express emotion='smile'/>")
    }
    var missing = try generator()
    #expect(throws: GenerationError.invalidParameters) { try missing.append("<say/>") }
}

private struct MarkupChat: ChatCapability {
    let availability: CapabilityAvailability = .available
    let markup: String
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        for part in [String(markup.prefix(7)), String(markup.dropFirst(7))] { try pair.emitter.yield(.text(part)) }
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}

@Test func assistantEmitsResolvedMarkupAndLiteralToolResultsCannotExecuteTags() async throws {
    let agent = try AssistantAgent(
        chat: MarkupChat(markup: "<channel.main>你好<express emotion='smile'/></channel.main>尾巴"))
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = agent.outputs.makeAsyncIterator()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("hello")))
    var calls: [ActionCall] = []
    for _ in 0..<6 {
        let output = try #require(await outputs.next()).output
        if case .actionCall(let call) = output {
            calls.append(call)
        } else {
            #expect(output == .control("assistant.finished"))
        }
    }
    #expect(calls.map(\.channel) == ["main", "main", "main", "Speech", "Display"])
    #expect(calls[2].actionPath.function == "express")
    let result = ToolResult(callID: UUID(), value: "<express emotion='smile'/>")
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .toolResult(result)))
    let literal = try #require(await outputs.next()).output
    #expect(
        await speechRequests.restored(literal)
            == .actionCall(expectedActionCall(name: "say", parameters: ["text": "<express emotion='smile'/>"])))
    await agent.stop()
}

@Test func incompleteModelMarkupFailsTurnAndFreshTurnGetsFreshParser() async throws {
    let agent = try AssistantAgent(chat: MarkupChat(markup: "<channel.main>未结束"))
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = agent.outputs.makeAsyncIterator()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("hello")))
    let output = try #require(await outputs.next()).output
    guard case .control(let state) = output else {
        Issue.record("Expected parse failure")
        await agent.stop()
        return
    }
    #expect(state.hasPrefix("assistant.error:"))
    try await agent.receive(
        AgentInput(sessionID: UUID(), payload: .toolResult(ToolResult(callID: UUID(), value: "recovered"))))
    #expect(
        await speechRequests.restored(try #require(await outputs.next()).output)
            == .actionCall(expectedActionCall(name: "say", parameters: ["text": "recovered"])))
    await agent.stop()
}

private func generationTrace() throws -> GenerationTrace {
    let configuration = try AgentConfigurations.load(named: "Assistant")
    return try GenerationTrace(capabilities: configuration.capabilities, textActions: configuration.textActions)
}

@Test func generationTraceRetainsRawFragmentsAndResolvedChannels() throws {
    let fragments = [" 你好 &amp; ", "世界。<channel.ma", "in><express emotion='smile'/>", "再见", "</channel.main>默认。\n"]
    var trace = try generationTrace()
    var expected = try generator()
    var calls: [ActionCall] = []
    for fragment in fragments {
        try trace.append(fragment)
        calls += try expected.append(fragment)
    }
    trace.finish()
    calls += try expected.finish()
    #expect(trace.raw == fragments.joined())
    #expect(trace.fragments == fragments)
    #expect(trace.calls == calls)
    #expect(trace.calls.map(\.channel) == ["Speech", "Display", "main", "main", "main", "Speech", "Display"])
    #expect(trace.parserError == nil)
    #expect(trace.finished)
}

@Test func generationTraceKeepsCollectingAfterParserFailure() throws {
    var trace = try generationTrace()
    try trace.append("<express emotion='smile'/>")
    try trace.append("<channel.unknown><express emotion='smile'/>broken")
    #expect(trace.parserError != nil)
    let failure = trace.parserError
    try trace.append("\n仍然保留原文 &bogus; <unfinished")
    trace.finish()
    #expect(
        trace.raw
            == "<express emotion='smile'/><channel.unknown><express emotion='smile'/>broken\n仍然保留原文 &bogus; <unfinished"
    )
    #expect(trace.fragments.count == 3)
    #expect(trace.calls.count == 1)
    #expect(trace.parserError == failure)
}

@Test func generationTraceReportsUnclosedMarkupAtFinish() throws {
    var trace = try generationTrace()
    try trace.append("<express emotion='")
    #expect(trace.parserError == nil)
    #expect(!trace.finished)
    trace.finish()
    #expect(trace.parserError?.hasPrefix("finish:") == true)
    #expect(trace.raw == "<express emotion='")
    #expect(throws: GenerationError.closed) { try trace.append("smile'/>") }
}

@Test func generationTraceBoundsFailExplicitlyWithoutEvictingExistingText() throws {
    var bytes = try generationTrace()
    let source = String(repeating: "x", count: GenerationTrace.maximumBytes)
    try bytes.append(source)
    #expect(throws: GenerationError.limitExceeded) { try bytes.append("x") }
    #expect(bytes.raw == source)
    #expect(!bytes.finished)
    var fragments = try generationTrace()
    for _ in 0..<GenerationTrace.maximumFragments { try fragments.append("") }
    #expect(throws: GenerationError.limitExceeded) { try fragments.append("excess") }
    #expect(fragments.fragments.count == GenerationTrace.maximumFragments)
    #expect(fragments.raw.isEmpty)
}
