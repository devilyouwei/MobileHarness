import AgentCore
import Foundation
import ModelKit
import StorageCore
import Testing

@testable import Agents

private func generator() throws -> AgentGenerator {
    try AgentGenerator(
        capabilities: AgentSkillLoader.registry(
            ["expression-interaction", "robot-interaction", "photography"],
            fixed: AgentConfigurations.load(named: "Assistant").capabilities), textMapping: AssistantAgent.mapText,
        segmentation: try AssistantAgent.textSegmentation)
}

@Test(.actionCatalog) func xmlActionsDiscardUndeclaredParametersBeforeAuthorization() throws {
    let capabilities = try AgentSkillLoader.registry(
        ["application-control"], fixed: AgentConfigurations.load(named: "Assistant").capabilities)
    var parser = AgentGenerator(capabilities: capabilities)
    let events =
        try parser.append(
            "<Bluetooth.control operation='disconnect' id='irrelevant' unexpected='extra' fence='untrusted'/>"
                + "<Bluetooth.readStatus id='irrelevant' unexpected='extra'/>") + parser.finish()
    let calls = events.compactMap(\.actionCall)
    #expect(calls.count == 2)
    #expect(calls.first?.parameters == ["operation": "disconnect", "id": "irrelevant"])
    #expect(calls.last?.parameters == [:])
    #expect(calls.allSatisfy { capabilities.permits($0) })

    // Directly constructed calls do not receive XML normalization or expanded permissions.
    let direct = ActionCall(
        actionPath: .init(domain: "System", module: "Device", function: "control"), channel: "System",
        parameters: ["operation": "disconnect", "unexpected": "extra"])
    #expect(!capabilities.permits(direct))
    let tools = try CapabilityRegistry(
        tools: [ToolRegistration(alias: "lookup", path: "Memory.Query.lookup", requiredParameters: ["query"])])
    #expect(throws: GenerationError.invalidParameters) {
        try tools.resolveTool("lookup", arguments: ["query": "x", "unexpected": "extra"])
    }
}

@Test(.actionCatalog) func xmlParameterTolerancePreservesRequiredKeysAndRawBounds() throws {
    let capabilities = try CapabilityRegistry(actions: [
        ActionRegistration(
            alias: "perform", path: .init(domain: "Fixture", module: "Control", function: "perform"),
            defaultChannel: "System", requiredParameters: ["operation"], optionalParameters: ["id"])
    ])
    var missing = AgentGenerator(capabilities: capabilities)
    #expect(
        try missing.append("<perform operaton='disconnect' extra='ignored'/>") == [
            .rejected(CallRejection(kind: .action, alias: "perform", reason: .invalidParameters))
        ])
    #expect(throws: GenerationError.invalidParameters) {
        try capabilities.resolveAction(
            "perform", parameters: ["operation": "disconnect", "extra": String(repeating: "x", count: 4097)])
    }
    var excessive = ["operation": "disconnect"]
    for index in 0..<32 { excessive["extra\(index)"] = "ignored" }
    #expect(throws: GenerationError.invalidParameters) {
        try capabilities.resolveAction("perform", parameters: excessive)
    }
    #expect(throws: GenerationError.invalidParameters) {
        try capabilities.resolveAction("perform", parameters: ["operation": "disconnect", "bad key": "ignored"])
    }
    var oversized = AgentGenerator(capabilities: capabilities)
    #expect(throws: GenerationError.limitExceeded) {
        try oversized.append("<perform operation='disconnect' extra='" + String(repeating: "x", count: 4096) + "'/>")
    }
}

@Test(.actionCatalog) func functionTokenParserEveryByteSplitPreservesActionsTextAndNestedChannels() throws {
    let source =
        "前👨‍👩‍👧。<channel.Speech>你好 &amp; 世界<express emotion='smile'/><channel.Display><express emotion='a&gt;b &quot;引号&quot;'/></channel.Display>再见</channel.Speech>默认。"
    let data = Data(source.utf8)
    var whole = try generator()
    let expected = try whole.append(data) + whole.finish()
    for split in 0...data.count {
        var parser = try generator()
        let actual = try parser.append(data.prefix(split)) + parser.append(data.dropFirst(split)) + parser.finish()
        #expect(normalizeToolIDs(actual) == normalizeToolIDs(expected), "UTF-8 split \(split)")
    }
    var bytewise = try generator()
    var actual: [GenerationEvent] = []
    for byte in data { actual += try bytewise.append(Data([byte])) }
    actual += try bytewise.finish()
    #expect(normalizeToolIDs(actual) == normalizeToolIDs(expected))
    #expect(
        expected.compactMap(\.actionCall).map(\.channel) == [
            "Speech", "Display", "Speech", "Display", "Speech", "Display", "Speech", "Display", "Speech", "Display",
        ])
    #expect(expected[2].actionCall?.parameters["text"] == "你好 & 世界")
    #expect(expected[5].actionCall?.parameters["emotion"] == "a>b \"引号\"")
}

@Test(.actionCatalog) func functionTokenParserStreamsCompleteActionsWithoutWaitingForChannelClose() throws {
    var parser = try generator()
    #expect(try parser.append("<channel.Spe").isEmpty)
    #expect(try parser.append("ech><express emotion='smile'").isEmpty)
    let early = try parser.append("/>")
    #expect(early.count == 1)
    #expect(early.first?.actionCall?.channel == "Speech")
    let next = try parser.append("</channel.Speech><express emotion='smile'/>")
    #expect(next.first?.actionCall?.channel == "Display")
    #expect(try parser.finish().isEmpty)
}

@Test(
    .actionCatalog,
    arguments: [
        "<express></express>", "</express>", "<channel.Speech/>", "<channel.Speech></channel.Display>",
        "</channel.Speech>", "<!-- comment -->", "<!DOCTYPE x>", "<?xml version='1.0'?>", "<![CDATA[x]]>",
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

@Test(.actionCatalog, arguments: ["<express", "<say text='unfinished", "&amp", "<channel.Speech>text"])
func functionTokenParserRejectsTruncatedCompletion(_ source: String) throws {
    var parser = FunctionTokenParser()
    _ = try parser.append(source)
    #expect(throws: GenerationError.incompleteDocument) { try parser.finish() }
}

@Test(.actionCatalog) func parserLimitsAndInvalidUTF8FailExplicitly() throws {
    var invalid = FunctionTokenParser()
    #expect(throws: GenerationError.invalidUTF8) { try invalid.append(Data([0xF0, 0x28])) }
    var partial = FunctionTokenParser()
    _ = try partial.append(Data([0xF0, 0x9F]))
    #expect(throws: GenerationError.incompleteDocument) { try partial.finish() }
    var depth = FunctionTokenParser()
    #expect(throws: GenerationError.limitExceeded) { try depth.append(String(repeating: "<channel.Speech>", count: 9)) }
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

@Test(.actionCatalog) func capabilityAliasesAreAgentLocalAndToolsUseSeparateProtocol() throws {
    let camera = try CapabilityRegistry(
        actions: [
            ActionRegistration(
                alias: "say", path: ActionPath(domain: "Robot", module: "Control", function: "speak"),
                defaultChannel: "robot",
                requiredParameters: ["text"])
        ], tools: [ToolRegistration(alias: "lookup", path: "Memory.Query.lookup", requiredParameters: ["query"])])
    var other = AgentGenerator(
        capabilities: camera,
        textMapping: { text, channel in
            [.action(try camera.resolveAction("say", parameters: ["text": text], channel: channel))]
        })
    let calls = try other.append("hello") + other.finish()
    #expect(
        calls.count == 1 && calls[0].actionCall?.actionPath.domain == "Robot" && calls[0].actionCall?.channel == "robot"
    )
    let id = UUID().uuidString
    let tool = try ToolCallParser.parse(
        id: id, alias: "lookup", argumentsJSON: Data(#"{"query":"x"}"#.utf8), capabilities: camera)
    #expect(tool.id == id && tool.toolPath == "Memory.Query.lookup" && tool.arguments == ["query": "x"])
    #expect(throws: GenerationError.invalidParameters) {
        try ToolCallParser.parse(
            id: id, alias: "lookup", argumentsJSON: Data(#"{"query":4}"#.utf8), capabilities: camera)
    }
    #expect(throws: GenerationError.duplicateAlias) {
        try CapabilityRegistry(
            actions: camera.actions, tools: [ToolRegistration(alias: "say", path: "Other.Playback.say")])
    }
    var xmlTool = AgentGenerator(
        capabilities: camera,
        textMapping: { text, channel in
            [.action(try camera.resolveAction("say", parameters: ["text": text], channel: channel))]
        })
    #expect(
        try xmlTool.append("<lookup query='x'/>") == [
            .rejected(
                CallRejection(kind: .action, alias: "lookup", reason: .unknownCapability))
        ])
    var forbidden = try generator()
    #expect(throws: GenerationError.forbiddenChannel) {
        try forbidden.append("<channel.robot><express emotion='smile'/>")
    }
    var missing = try generator()
    #expect(
        try missing.append("<express/>") == [
            .rejected(
                CallRejection(kind: .action, alias: "express", reason: .invalidParameters))
        ])
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

@Test(.actionCatalog) func assistantEmitsResolvedMarkupAndLiteralToolResultsCannotExecuteTags() async throws {
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: MarkupChat(markup: "<channel.Speech>你好<express emotion='smile'/></channel.Speech>尾巴"),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    try await agent.receive(
        AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("hello")))
    var calls: [ActionCall] = []
    for _ in 0..<6 {
        let output = try #require(try await outputs.next()).output
        if case .actionCall(let call) = output {
            calls.append(call)
        } else if case .toolCall(let tool) = output {
            #expect(tool.toolPath == "UI.Caption.print")
        } else {
            #expect(output == .control("agent.finished"))
        }
    }
    #expect(calls.map(\.channel) == ["Speech", "Display", "Speech", "Speech", "Display"])
    #expect(calls[2].actionPath.function == "express")
    let result = ToolResult(callID: UUID().uuidString, value: "<express emotion='smile'/>")
    try await agent.receive(
        AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .toolResult(result)))
    let literal = try #require(try await outputs.next()).output
    #expect(
        await speechRequests.restored(literal)
            == .actionCall(expectedActionCall(name: "say", parameters: ["text": "<express emotion='smile'/>"])))
    await agent.stop()
}

@Test(.actionCatalog) func incompleteModelMarkupFailsTurnAndFreshTurnGetsFreshParser() async throws {
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: MarkupChat(markup: "<channel.Speech>未结束"),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    let speechRequests = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    try await agent.receive(
        AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("hello")))
    let output = try #require(try await outputs.next()).output
    guard case .control(let state) = output else {
        Issue.record("Expected parse failure")
        await agent.stop()
        return
    }
    #expect(state.hasPrefix("agent.error:"))
    try await agent.receive(
        AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString,
            payload: .toolResult(ToolResult(callID: UUID().uuidString, value: "recovered"))))
    #expect(
        await speechRequests.restored(try #require(try await outputs.next()).output)
            == .actionCall(expectedActionCall(name: "say", parameters: ["text": "recovered"])))
    await agent.stop()
}

private func generationTrace() throws -> GenerationTrace {
    let configuration = try AgentConfigurations.load(named: "Assistant")
    return GenerationTrace(
        capabilities: try AgentSkillLoader.registry(
            ["expression-interaction", "robot-interaction", "photography"], fixed: configuration.capabilities),
        textMapping: AssistantAgent.mapText,
        segmentation: try AssistantAgent.textSegmentation)
}

@Test(.actionCatalog) func generationTraceRetainsRawFragmentsAndResolvedChannels() throws {
    let fragments = [" 你好 &amp; ", "世界。<channel.Spe", "ech><express emotion='smile'/>", "再见", "</channel.Speech>默认。\n"]
    var trace = try generationTrace()
    var expected = try generator()
    var calls: [GenerationEvent] = []
    for fragment in fragments {
        try trace.append(fragment)
        calls += try expected.append(fragment)
    }
    trace.finish()
    calls += try expected.finish()
    #expect(trace.raw == fragments.joined())
    #expect(trace.fragments == fragments)
    #expect(normalizeToolIDs(trace.events) == normalizeToolIDs(calls))
    #expect(
        trace.calls.filter { $0.actionPath.module != "Caption" }.map(\.channel) == [
            "Speech", "Speech", "Speech", "Speech",
        ])
    #expect(trace.parserError == nil)
    #expect(trace.finished)
}

@Test(.actionCatalog) func generationTraceKeepsCollectingAfterParserFailure() throws {
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

@Test(.actionCatalog) func generationTraceReportsUnclosedMarkupAtFinish() throws {
    var trace = try generationTrace()
    try trace.append("<express emotion='")
    #expect(trace.parserError == nil)
    #expect(!trace.finished)
    trace.finish()
    #expect(trace.parserError?.hasPrefix("finish:") == true)
    #expect(trace.raw == "<express emotion='")
    #expect(throws: GenerationError.closed) { try trace.append("smile'/>") }
}

@Test(.actionCatalog) func generationTraceBoundsFailExplicitlyWithoutEvictingExistingText() throws {
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

@Test(.actionCatalog) func waitGenerationPreservesNestedBoundariesAcrossEveryByteSplit() throws {
    let source = "前。<wait><channel.Speech>甲<wait><express emotion='smile'/>乙</wait>丙</channel.Speech></wait>后。"
    let bytes = Data(source.utf8)
    var whole = try generator()
    let expected = try whole.append(bytes) + whole.finish()
    #expect(
        expected.filter { if case .scheduling = $0 { true } else { false } } == [
            .scheduling(.beginWait), .scheduling(.beginWait), .scheduling(.endWait), .scheduling(.endWait),
        ])
    let calls = expected.compactMap(\.actionCall).filter { $0.actionPath.module != "Caption" }
    #expect(
        calls.map(\.channel) == [
            "Speech", "Speech", "Speech", "Speech", "Speech", "Speech",
        ])
    for split in 0...bytes.count {
        var incremental = try generator()
        let actual =
            try incremental.append(bytes.prefix(split)) + incremental.append(bytes.dropFirst(split))
            + incremental.finish()
        #expect(normalizeToolIDs(actual) == normalizeToolIDs(expected))
    }
    var trace = try generationTrace()
    try trace.append(source)
    trace.finish()
    #expect(normalizeToolIDs(trace.events) == normalizeToolIDs(expected))
    #expect(trace.raw == source)
}

@Test(
    .actionCatalog,
    arguments: [
        "<wait/>", "<wait x='1'>", "</wait>", "<wait><channel.Speech></wait></channel.Speech>",
        "<channel.Speech><wait></channel.Speech></wait>",
    ])
func invalidWaitSyntaxIsRejected(_ source: String) throws {
    var parser = FunctionTokenParser()
    #expect(throws: GenerationError.malformedMarkup) { try parser.append(source) }
}

@Test(.actionCatalog) func waitLimitsEmptyScopesAndReservedAlias() throws {
    var empty = try generator()
    #expect(try empty.append("<wait></wait>") == [.scheduling(.beginWait), .scheduling(.endWait)])
    #expect(try empty.finish().isEmpty)
    var depth = FunctionTokenParser()
    #expect(throws: GenerationError.limitExceeded) {
        try depth.append(String(repeating: "<wait><channel.Speech>", count: 5))
    }
    var groups = FunctionTokenParser()
    _ = try groups.append(String(repeating: "<wait></wait>", count: 32))
    #expect(throws: GenerationError.limitExceeded) { try groups.append("<wait>") }
    var unfinished = FunctionTokenParser()
    _ = try unfinished.append("<wait>")
    #expect(throws: GenerationError.incompleteDocument) { try unfinished.finish() }
    #expect(throws: GenerationError.invalidParameters) {
        try CapabilityRegistry(actions: [
            ActionRegistration(
                alias: "wait", path: .init(domain: "UI", module: "Control", function: "wait"), defaultChannel: "Display"
            )
        ])
    }
    #expect(!((try AgentConfigurations.load(named: "Assistant")).capabilities.channels.contains("main")))
}

@Test(.actionCatalog) func assistantPreservesWaitEventsAroundSpeechHandleConversion() async throws {
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: MarkupChat(markup: "<wait>你好。</wait><wait><express emotion='smile'/></wait>"),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    let probe = try await bindSpeechRequests(agent)
    try await agent.start()
    try await agent.receive(
        AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("test")))
    var received: [AgentOutput] = []
    for try await envelope in FixtureGenerationOutputs(agent: agent) {
        received.append(await probe.restored(envelope.output))
        if case .control = envelope.output { break }
    }
    #expect(
        received == [
            .scheduling(.beginWait),
            .actionCall(expectedActionCall(name: "say", parameters: ["text": "你好。"])),
            expectedPrint("你好。"),
            .scheduling(.endWait), .scheduling(.beginWait),
            .actionCall(expectedActionCall(name: "express", parameters: ["emotion": "smile"])),
            .scheduling(.endWait), .control("agent.finished"),
        ])
    await agent.stop()
}

@Test(.actionCatalog) func rejectedActionsPreserveValidCallsAndWaitBoundaries() throws {
    var parser = try generator()
    let events =
        try parser.append(
            "<wait><express emotion='smile'/><unknown/><express/><express emotion='sad'/></wait>")
        + parser.finish()
    #expect(events.count == 6)
    #expect(events.first == .scheduling(.beginWait))
    #expect(events.last == .scheduling(.endWait))
    #expect(events.compactMap(\.actionCall).count == 2)
    #expect(events[2] == .rejected(CallRejection(kind: .action, alias: "unknown", reason: .unknownCapability)))
    #expect(events[3] == .rejected(CallRejection(kind: .action, alias: "express", reason: .invalidParameters)))
}
