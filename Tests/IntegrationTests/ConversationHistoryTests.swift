import Actions
import AgentCore
import Agents
import Foundation
@_spi(ModelManagement) import ModelKit
import StorageChat
import StorageCore
import StorageFiles
import StorageMedia
import StorageSQLite
import StorageState
import StorageTasks
import Testing

@testable import ModelKitOpenAI

private actor LiveTitleChatProbe: ChatCapability {
    let provider: OpenAIChat
    var request: ChatRequest?
    let timing = ChatTiming()
    init(provider: OpenAIChat) { self.provider = provider }
    var availability: CapabilityAvailability { .available }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        var sampled = request
        sampled.timing = timing
        self.request = sampled
        return try await provider.chat(sampled)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_LIVE_CHAT"] == "1"))
func liveCloudTitleUsesProductionGenerator() async throws {
    let environment = ProcessInfo.processInfo.environment
    let endpoint = try #require(environment["HARNESS_LIVE_CHAT_URL"])
    let key = try #require(environment["HARNESS_LIVE_CHAT_KEY"])
    let model = try #require(environment["HARNESS_LIVE_CHAT_MODEL"])
    let configuration = try OpenAIChatConfiguration(
        baseURL: OpenAIChatConfiguration.endpoint(endpoint), apiKey: key, model: model)
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32)
    let provider = try OpenAIChat(context: context, configuration: configuration)
    let probe = LiveTitleChatProbe(provider: provider)
    let store = ConversationHistoryStore()
    let id = UUID().uuidString
    _ = try await store.beginFixture(
        id: id, user: "请介绍如何拍摄室内人像照片，安排补光与人物姿态。", system: "fixture", model: "synthetic")
    try await store.append("可使用窗边柔光，保持背景简洁并调整人物角度。", to: id)
    try await store.finish(id, state: .completed)
    let conversation = try #require(try await store.startNew())
    do {
        let title = try await ConversationTitleGenerator.summarize(conversation, using: probe)
        #expect(!title.isEmpty && title.count <= 80 && !title.contains("\n"))
        print(
            "LIVE_TITLE model=\(model) success=true title_characters=\(title.count) ttft=\(String(describing: probe.timing.snapshot?.firstTokenLatency))"
        )
        try await context.unload()
        let sampled = try #require(await probe.request)
        let http = try configuration.request(sampled)
        let encoded = try #require(http.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect((body["reasoning"] as? [String: String])?["effort"] == "none")
        #expect(body["enable_thinking"] as? Bool == false)
        #expect(body["max_output_tokens"] as? Int == 64)
        // A separate explicit probe checks the same synthetic request's server-side thinking metadata.
        let (data, response) = try await URLSession.shared.data(for: http)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        try #require(data.count <= 65536)
        var reasoningTokens: Int?
        var reasoningEvents = 0
        var completed = false
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
        where line.hasPrefix("data:") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
            else { continue }
            if (object["type"] as? String)?.hasPrefix("response.reasoning_text.") == true { reasoningEvents += 1 }
            if object["type"] as? String == "response.completed", let terminal = object["response"] as? [String: Any] {
                completed = terminal["status"] as? String == "completed"
                let usage = terminal["usage"] as? [String: Any]
                reasoningTokens = (usage?["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
            }
        }
        #expect(completed && reasoningEvents == 0 && reasoningTokens == 0)
        print(
            "LIVE_TITLE wire_completed=\(completed) reasoning_events=\(reasoningEvents) reasoning_tokens=\(String(describing: reasoningTokens))"
        )
    } catch {
        try await context.unload()
        print(
            "LIVE_TITLE model=\(model) error=\(error) ttft=\(String(describing: probe.timing.snapshot?.firstTokenLatency))"
        )
        let request = try #require(await probe.request)
        let (data, response) = try await URLSession.shared.data(for: configuration.request(request))
        print("LIVE_TITLE diagnostic_status=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        if data.count <= 65536 {
            var types: Set<String> = []
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            where line.hasPrefix("data:") {
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                else { continue }
                if let type = object["type"] as? String { types.insert(type) }
                if let terminal = object["response"] as? [String: Any],
                    ["response.completed", "response.incomplete", "response.failed"].contains(
                        object["type"] as? String ?? "")
                {
                    let details = [
                        "status": terminal["status"] ?? "missing", "usage": terminal["usage"] ?? [:],
                        "incomplete_details": terminal["incomplete_details"] ?? [:],
                    ]
                    let encoded = try JSONSerialization.data(withJSONObject: details, options: [.sortedKeys])
                    print(
                        "LIVE_TITLE terminal=\(String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: key, with: "[REDACTED]"))"
                    )
                }
            }
            print("LIVE_TITLE event_types=\(types.sorted())")
        }
        throw error
    }
}

private func journal(at url: URL) throws -> ConversationHistoryStore {
    ConversationHistoryStore(records: try testConversationRecords(directory: url.deletingLastPathComponent()))
}

@Test(.actionCatalog) func conversationJournalRestoresRawRequestAndMarksInterruptedGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let first = try journal(at: url)
    let id = UUID().uuidString
    let original = "  用户原文\n串行执行  "
    let request = try await first.beginFixture(id: id, user: original, system: "system", model: "gpt-4.1")
    #expect(request.request.last?.content == original)
    try await first.append("<wait>\n", to: id)
    try await first.append("hello &amp; world", to: id)
    let recovered = try await journal(at: url).snapshot()
    let turn = try #require(recovered.current.turns.first)
    #expect(turn.user == original && recovered.current.turns.last?.user == original)
    #expect(turn.response.isEmpty)
    #expect(turn.raw.isEmpty)
    #expect(turn.request == request.request)
    #expect(turn.state == .interrupted)
    #expect(recovered.current.summaryTitle == nil)
}

@Test(.actionCatalog) func contextUsesTenTerminalRoundsAndNewConversationIsIsolated() async throws {
    let store = ConversationHistoryStore()
    for index in 0..<12 {
        let id = UUID().uuidString
        _ = try await store.beginFixture(id: id, user: "question \(index)", system: "system", model: "fixture")
        try await store.beginModelRequest(
            .init(id: UUID().uuidString, input: "question \(index)", requestJSON: "[]"), for: id)
        try await store.append("answer \(index)", to: id)
        try await store.finish(id, state: .completed, reason: "stop")
    }
    let failed = UUID().uuidString
    _ = try await store.beginFixture(id: failed, user: "failed question", system: "system", model: "fixture")
    try await store.append("<wait/>", to: failed)
    try await store.finish(failed, state: .failed, error: "bad syntax")
    let id = UUID().uuidString
    let request = try await store.beginFixture(id: id, user: "next", system: "new system", model: "fixture")
    try #require(request.request.count == 22)
    #expect(request.request[1].content == "question 3")
    #expect(request.request[18].content == "answer 11")
    #expect(request.request.contains { $0.content == "<wait/>" })
    await #expect(throws: ConversationHistoryError.busy) { try await store.startNew() }
    try await store.finish(id, state: .cancelled)
    let past = try #require(try await store.startNew())
    #expect(past.turns.count == 14 && past.archivedAt != nil)
    let fresh = try await store.beginFixture(
        id: UUID().uuidString, user: "fresh", system: "system", model: "fixture")
    #expect(fresh.request.count == 2)
    try await store.setTitle("A summarized topic", for: past.id)
    let snapshot = try await store.snapshot()
    #expect(snapshot.current.turns.last?.user == "fresh" && snapshot.current.summaryTitle == nil)
    #expect(snapshot.past.first?.summaryTitle == "A summarized topic")
    try await store.deleteArchived(past.id)
    #expect(try await store.snapshot().past.isEmpty)
}

@Test(.actionCatalog) func rawOverflowPreservesPrefixAndAdmissionFailureDoesNotOverwriteJournal() async throws {
    let store = ConversationHistoryStore()
    let id = UUID().uuidString
    _ = try await store.beginFixture(id: id, user: "original", system: "system", model: "fixture")
    let prefix = String(repeating: "x", count: 262144)
    try await store.append(prefix, to: id)
    await #expect(throws: ConversationHistoryError.capacityExceeded) { try await store.append("x", to: id) }
    try await store.finish(id, state: .failed, error: "overflow")
    #expect(try await store.snapshot().current.turns.first?.raw == prefix)
    await #expect(throws: ConversationHistoryError.invalidRecord) {
        try await store.beginFixture(
            id: UUID().uuidString, user: String(repeating: "x", count: 4097), system: "system",
            model: "fixture")
    }
    #expect(try await store.snapshot().current.turns.count == 1)
}

private actor HistoryModel: ChatCapability {
    let availability: CapabilityAvailability = .available
    let text: String
    let leaveOpen: Bool
    let finishReason: ChatEvent.FinishReason
    var requests: [ChatRequest] = []
    init(_ text: String, leaveOpen: Bool = false, finishReason: ChatEvent.FinishReason = .stop) {
        self.text = text
        self.leaveOpen = leaveOpen
        self.finishReason = finishReason
    }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text(text))
        if !leaveOpen {
            try pair.emitter.yield(.finished(finishReason))
            pair.emitter.finish()
        }
        return pair.session
    }
}

@Test(.actionCatalog) func assistantRecordsMalformedOutputBeforeParsingAndContextSurvivesNewInstance() async throws {
    let store = ConversationHistoryStore()
    let model = HistoryModel("<wait/>")
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: model, conversations: store,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    try await agent.start()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("请串行"))
    try await agent.receive(input)
    var iterator = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    let output = try #require(try await iterator.next())
    guard case .control(let message) = output.output else {
        Issue.record("Expected error")
        return
    }
    #expect(message.hasPrefix("agent.error:"))
    let turn = try #require(try await store.snapshot().current.turns.first)
    #expect(turn.user == "请串行" && turn.state == .failed)
    #expect(turn.raw == "<wait/>")
    #expect(await model.requests.count == 1)
    #expect(turn.modelRequests?.allSatisfy { $0.state == .failed && $0.response == "<wait/>" } == true)
    #expect(turn.error != nil)
    await agent.stop()
}

@Test(.actionCatalog) func cancellationPersistsReceivedTextBeforeStoppingProducer() async throws {
    let store = ConversationHistoryStore()
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: HistoryModel("partial", leaveOpen: true), conversations: store,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    try await agent.start()
    try await agent.receive(
        AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("original")))
    for _ in 0..<10000 {
        if let snapshot = try? await store.snapshot(), snapshot.current.turns.first?.raw == "partial" { break }
        await Task.yield()
    }
    await agent.stop()
    let turn = try #require(try await store.snapshot().current.turns.first)
    #expect(turn.raw == "partial" && turn.state == .cancelled)
}

@Test(.actionCatalog) func titleGenerationIsSeparateAndStoredOnlyOnArchivedConversation() async throws {
    let store = ConversationHistoryStore()
    let id = UUID().uuidString
    _ = try await store.beginFixture(id: id, user: "Compare channel and wait", system: "system", model: "fixture")
    try await store.append("Some answer", to: id)
    try await store.finish(id, state: .completed)
    let archived = try #require(try await store.startNew())
    let model = HistoryModel("Channel and wait coordination")
    let title = try await ConversationTitleGenerator.summarize(archived, using: model)
    try await store.setTitle(title, for: archived.id)
    #expect(try await store.snapshot().past.first?.summaryTitle == title)
    #expect(try await store.snapshot().current.turns.isEmpty)
    let request = try #require(await model.requests.first)
    #expect(request.maximumOutputTokens == 64)
    #expect(!request.messages[0].content.contains("CALLABLE ACTIONS"))
    await #expect(throws: (any Error).self) {
        try await ConversationTitleGenerator.summarize(archived, using: HistoryModel("<wait/>"))
    }
}

@Test(arguments: ["", "Partial title"])
func titleGenerationNeverAcceptsIncompleteOutput(text: String) async throws {
    let store = ConversationHistoryStore()
    let id = UUID().uuidString
    _ = try await store.beginFixture(id: id, user: "Synthetic title subject", system: "fixture", model: "synthetic")
    try await store.append("Fixture answer", to: id)
    try await store.finish(id, state: .completed)
    let archived = try #require(try await store.startNew())
    await #expect(throws: CapabilityError.invalidRequest("Incomplete conversation title")) {
        try await ConversationTitleGenerator.summarize(archived, using: HistoryModel(text, finishReason: .lengthLimit))
    }
}

@Test(.actionCatalog) func assistantLoadsSQLiteHistoryWithFreshRuntimeWithoutReplayingActions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scope = UUID().uuidString
    let firstRepository = try AgentContextRepository(
        agent: .assistant, scope: scope, state: AssistantContextState()
    )
    let firstStore = try fixtureAssistantStore(repository: firstRepository, directory: directory)
    let previousID = UUID().uuidString
    _ = try await firstStore.beginFixture(id: previousID, user: "previous user", system: "old system", model: "fixture")
    try await firstStore.beginModelRequest(
        .init(id: UUID().uuidString, input: "previous user", requestJSON: "[]"), for: previousID)
    try await firstStore.append("<express emotion=\"happy\"/>", to: previousID)
    try await firstStore.finish(previousID, state: .completed, reason: "stop")
    let model = HistoryModel("<express emotion=\"smile\"/>")
    let repository = try AgentContextRepository(
        agent: .assistant, scope: scope, state: AssistantContextState()
    )
    let restored = try fixtureAssistantStore(repository: repository, directory: directory)
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(), chat: model, conversations: restored, context: repository)
    try await agent.start()
    try await agent.receive(
        AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("continue")))
    var iterator = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    let action = try #require(try await iterator.next())
    #expect(action.output == .actionCall(expectedActionCall(name: "express", parameters: ["emotion": "smile"])))
    #expect(try await iterator.next()?.output == .control("agent.finished"))
    let request = try #require(await model.requests.first)
    try #require(request.messages.count == 5)
    #expect(request.messages.last?.content == "continue")
    #expect(
        request.messages.dropLast().last?.content.contains("# CURRENT STATE") == true)
    #expect(request.messages[1].content == "previous user")
    #expect(request.messages[2].content == "<express emotion=\"happy\"/>")
    let stored = try #require(try await restored.snapshot().current.turns.last?.modelRequests?.first)
    let sentMessages = try #require(
        JSONSerialization.jsonObject(with: Data(stored.requestJSON.utf8)) as? [[String: Any]])
    #expect(request.messages.map(\.content) == sentMessages.compactMap { $0["content"] as? String })
    await agent.stop()
    #expect(try await restored.snapshot().current.turns.count == 2)
}

@Test(.actionCatalog) func conversationTokenBudgetPreservesExplicitValuesAndDefault() async throws {
    let store = ConversationHistoryStore()
    let record = try await store.beginFixture(
        id: UUID().uuidString, user: "hello", system: "system", model: "fixture")
    #expect(record.maximumOutputTokens == nil)
    let encoded = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(ConversationRecord.self, from: encoded).maximumOutputTokens == nil)
    var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    fields["maximumOutputTokens"] = 256
    let restored = try JSONDecoder().decode(
        ConversationRecord.self, from: JSONSerialization.data(withJSONObject: fields))
    #expect(restored.maximumOutputTokens == 256)
}

@Test(.actionCatalog) func toolJournalPersistsInputsUsageAndLateArchivedOutcomes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let store = try journal(at: url)
    let id = UUID().uuidString
    _ = try await store.beginFixture(id: id, user: "打开摄像头", system: "system", model: "fixture")
    try await store.recordToolDefinitions(["camera declaration"], for: id)
    let call = ConversationToolCall(
        id: UUID().uuidString, providerID: "provider-1", name: "Camera.open", argumentsJSON: "{}")
    try await store.recordToolCall(call, for: id)
    try await store.recordTokenUsage(
        ConversationTokenUsage(input: 12, generated: 4, total: 16, cachedInput: 8, cacheWriteInput: 2), for: id)
    try await store.finish(id, state: .completed, reason: "toolCalls")
    let archivedID = try #require(try await store.startNew()).id
    try await store.recordToolOutcome(call.id, for: id, state: .completed)
    let restored = try #require(try await journal(at: url).conversation(archivedID).turns.first)
    #expect(restored.toolDefinitions == ["camera declaration"])
    #expect(
        restored.tokenUsage
            == ConversationTokenUsage(input: 12, generated: 4, total: 16, cachedInput: 8, cacheWriteInput: 2))
    let result = try #require(restored.toolCalls?.first)
    #expect(result.providerID == "provider-1" && result.argumentsJSON == "{}" && result.state == .completed)
    #expect(result.output == nil)
    try await store.recordToolOutcome(call.id, for: id, state: .failed, output: "permission denied", error: "fixture")
    #expect(try await store.conversation(archivedID).turns.first?.toolCalls?.first?.output == "permission denied")
    // An internal UI Tool or non-journal input does not create a model-call record.
    try await store.recordToolOutcome(
        UUID().uuidString, for: UUID().uuidString, state: .completed)
}

@Test(.actionCatalog) func admittedConversationRecordHasNoToolOrUsageEvidence() async throws {
    let store = ConversationHistoryStore()
    let record = try await store.beginFixture(
        id: UUID().uuidString, user: "input", system: "system", model: "fixture")
    let restored = try JSONDecoder().decode(ConversationRecord.self, from: JSONEncoder().encode(record))
    #expect(restored.toolCalls == nil && restored.toolDefinitions == nil && restored.tokenUsage == nil)
}

private struct NativeRuntimeHistoryChat: ChatCapability {
    var availability: CapabilityAvailability { .available }
    var supportsToolCalls: Bool { true }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        #expect(request.maximumOutputTokens == nil)
        #expect(request.tools.contains { $0.name == "runtimeInfo" })
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if request.messages.last?.role == .tool {
            try pair.emitter.yield(.text("<express emotion=\"smile\"/>"))
            try pair.emitter.yield(.finished(.stop))
            pair.emitter.finish()
            return pair.session
        }
        try pair.emitter.yield(.text("<express emotion=\"smile\"/>"))
        try pair.emitter.yield(
            .toolCall(ChatToolCall(id: "cloud-runtime", name: "runtimeInfo", argumentsJSON: "{}")))
        try pair.emitter.yield(.usage(try ChatTokenUsage(input: 100, generated: 20, total: 120)))
        try pair.emitter.yield(.finished(.toolCalls))
        pair.emitter.finish()
        return pair.session
    }
}

@Test(.actionCatalog) func assistantJournalsMixedActionNativeToolAndUsageWithRuntimeCorrelation() async throws {
    let store = ConversationHistoryStore()
    let agent = try FixtureNativeAgent(
        chat: NativeRuntimeHistoryChat(), conversations: store,
        context: try AgentContextRepository(
            agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    )
    try await agent.start()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("打开摄像头并微笑"))
    try await agent.receive(input)
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    var observedAction = false
    var native: ToolCall?
    while !observedAction || native == nil {
        let output = try #require(try await outputs.next())
        switch output.output {
        case .actionCall: observedAction = true
        case .toolCall(let call): native = call
        default:
            Issue.record("Unexpected generation output: \(output.output)")
            await agent.stop()
            return
        }
    }
    let call = try #require(native)
    #expect(call.toolPath == "System.Runtime.runtimeInfo")
    let feedbackPayload = InputPayload.toolResult(.init(callID: call.id, value: "completed"))
    try await agent.receive(
        AgentInput(
            id: UUID().uuidString,
            sessionID: input.sessionID, payload: feedbackPayload,
            metadata: InputMetadata(
                payload: feedbackPayload, source: "runtime", origin: .runtime, rootID: input.metadata.rootID,
                parentID: input.id)))
    while let output = try await outputs.next() { if output.output == .control("agent.finished") { break } }
    let record = try #require(try await store.snapshot().current.turns.first)
    #expect(record.state == .completed && record.finishReason == "stop")
    #expect(record.toolCalls?.first?.id == call.id)
    #expect(record.toolCalls?.first?.providerID == "cloud-runtime")
    #expect(record.toolCalls?.first?.state == .completed)
    #expect(record.tokenUsage?.generated == 20)
    #expect(record.toolDefinitions?.contains { $0.contains("runtimeInfo") } == true)
    let conversation = try await store.snapshot().current
    let actionOnly = try AssistantContextState.buildChatMessages(
        system: "actions", user: "next", conversation: conversation)
    #expect(actionOnly.contains { $0.role == .tool && $0.content == "completed" })
    #expect(actionOnly.contains { !$0.toolCalls.isEmpty })
    #expect(try ChatRequest(messages: actionOnly).tools.isEmpty)

    await agent.stop()
}

@Test(.actionCatalog) func concurrentGenerationAndToolOutcomesPreserveBothDurableUpdates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let store = try journal(at: url)
    let id = UUID().uuidString
    _ = try await store.beginFixture(id: id, user: "concurrent fixture", system: "system", model: "fixture")
    let call = ConversationToolCall(
        id: UUID().uuidString, providerID: "cloud", name: "Camera.close", argumentsJSON: "{}")
    try await store.recordToolCall(call, for: id)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<8 { group.addTask { try await store.append("fragment-\(index)", to: id) } }
        group.addTask { try await store.recordToolOutcome(call.id, for: id, state: .completed) }
        group.addTask {
            try await store.recordTokenUsage(ConversationTokenUsage(input: 1, generated: 2, total: 3), for: id)
        }
        try await group.waitForAll()
    }
    try await store.finish(id, state: .completed)
    let restored = try #require(try await journal(at: url).snapshot().current.turns.first)
    #expect((0..<8).allSatisfy { restored.response.contains("fragment-\($0)") })
    #expect(restored.toolCalls?.first?.state == .completed)
    #expect(restored.tokenUsage?.total == 3)
}

extension ConversationHistoryStore {
    fileprivate func beginFixture(id: String, user: String, system: String, model: String) async throws
        -> ConversationRecord
    {
        let read = try await readCurrent()
        let request = try ConversationContextBuilder.request(system: system, user: user, conversation: read.current)
        return try await begin(id: id, user: user, request: request, expecting: read.token, model: model)
    }
}

@Test(.actionCatalog) func historyRejectsStaleAndForeignReadTokens() async throws {
    let store = ConversationHistoryStore()
    let read = try await store.readCurrent()
    let request = [ConversationMessage(role: .user, content: "exact caller payload")]
    let id = UUID().uuidString
    let record = try await store.begin(id: id, user: "raw", request: request, expecting: read.token, model: "fixture")
    #expect(record.request == request)
    try await store.finish(id, state: .completed)
    await #expect(throws: ConversationHistoryError.conflict) {
        try await store.begin(
            id: UUID().uuidString, user: "raw", request: request, expecting: read.token, model: "fixture")
    }
    let beforeArchive = try await store.readCurrent()
    _ = try await store.startNew()
    await #expect(throws: ConversationHistoryError.conflict) {
        try await store.begin(
            id: UUID().uuidString, user: "raw", request: request, expecting: beforeArchive.token,
            model: "fixture")
    }
    let other = try await ConversationHistoryStore().readCurrent()
    await #expect(throws: ConversationHistoryError.conflict) {
        try await store.begin(
            id: UUID().uuidString, user: "raw", request: request, expecting: other.token, model: "fixture")
    }
    #expect(try await store.snapshot().current.turns.isEmpty)
}

@Test(.actionCatalog) func historyAdmitsUserAfterReplyUpdatesWithoutWeakeningRequestFence() async throws {
    let store = ConversationHistoryStore()
    let first = UUID().uuidString
    _ = try await store.admitUserInput(id: first, user: "first", model: "pending")
    let prior = try await store.readCurrent()
    try await store.append("partial reply", to: first)
    let second = UUID().uuidString
    await #expect(throws: ConversationHistoryError.conflict) {
        try await store.begin(
            id: second, user: "second", request: [], expecting: prior.token, model: "fixture")
    }
    let admitted = try await store.admitUserInput(id: second, user: "second", model: "pending")
    #expect(admitted.awaitingModel && admitted.request.isEmpty && admitted.state == .generating)
    let snapshot = try await store.snapshot()
    let current = snapshot.current
    #expect(current.id == prior.current.id)
    #expect(current.turns.map(\.id) == [first, second])
    #expect(current.turns.first?.response == "partial reply")
    await #expect(throws: ConversationHistoryError.invalidRecord) {
        try await store.admitUserInput(id: second, user: "second", model: "pending")
    }
    let afterDuplicate = try await store.snapshot()
    #expect(afterDuplicate.revision == snapshot.revision)
    #expect(afterDuplicate.current.turns.map(\.id) == [first, second])
}

@Test(.actionCatalog) func assistantConflictDoesNotCallModelOrWriteNewTurn() async throws {
    let store = ConversationHistoryStore()
    let model = HistoryModel("should not run")
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: model, conversations: store,
        modelName: {
            _ = try await store.startNew()
            return "fixture"
        },
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    try await agent.start()
    let previous = UUID().uuidString
    _ = try await store.beginFixture(id: previous, user: "previous", system: "system", model: "fixture")
    try await store.finish(previous, state: .completed)
    try await agent.receive(
        AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("next")))
    var iterator = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    guard case .control(let message) = try await iterator.next()?.output else {
        Issue.record("Expected admission error")
        await agent.stop()
        return
    }
    #expect(message.hasPrefix("agent.error:"))
    #expect(await model.requests.isEmpty)
    #expect(try await store.snapshot().current.turns.last?.user == "next")
    #expect(try await store.snapshot().current.turns.last?.state == .failed)
    await agent.stop()
}

@Test(.actionCatalog) func assistantPersistenceFailureDoesNotCallModel() async throws {
    let store = ConversationHistoryStore()
    let repository = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: AssistantContextState(),
        persistence: AgentContextPersistence(
            load: { nil },
            commit: { context, _ in
                if !context.records.isEmpty { throw DocumentStorageError.capacityExceeded }
            })
    )
    let model = HistoryModel("should not run")
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(), chat: model, conversations: store, context: repository)
    try await agent.start()
    await #expect(throws: DocumentStorageError.capacityExceeded) {
        try await agent.receive(
            AgentInput(
                id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("next")))
    }
    #expect(await model.requests.isEmpty)
    #expect(try await store.snapshot().current.turns.isEmpty)
    #expect(try await repository.snapshot().records.isEmpty)
    await agent.stop()
}

@Test(.actionCatalog) func modelRequestJournalKeepsFirstTokenUsageAndLateOutcomesWithTheirRequest() async throws {
    let store = ConversationHistoryStore()
    let id = UUID().uuidString
    _ = try await store.beginFixture(id: id, user: "question", system: "system", model: "fixture")
    let first = ConversationModelRequest(id: UUID().uuidString, input: "question", requestJSON: "[]")
    try await store.beginModelRequest(first, for: id)
    let arrival = first.date.addingTimeInterval(0.125)
    try await store.recordModelTiming(startedAt: first.date, firstTokenAt: arrival, latency: 0.125, for: id)
    try await store.recordModelTiming(
        startedAt: first.date, firstTokenAt: arrival.addingTimeInterval(1), latency: 1.125, for: id)
    try await store.append("first", to: id)
    let call = ConversationToolCall(
        id: UUID().uuidString, providerID: "provider", name: "inspect", argumentsJSON: "{}")
    try await store.recordToolCall(call, for: id)
    try await store.recordTokenUsage(.init(input: 2, generated: 3, total: 5), for: id)
    try await store.finishModelRequest(id, reason: "toolCalls")
    try await store.beginModelRequest(
        .init(id: UUID().uuidString, input: "result", requestJSON: "[]"), for: id)
    try await store.append("second", to: id)
    try await store.recordTokenUsage(.init(input: 6, generated: 7, total: 13), for: id)
    try await store.finishModelRequest(id, reason: "stop")
    try await store.finish(id, state: .completed)
    _ = try await store.startNew()
    try await store.recordToolOutcome(call.id, for: id, state: .completed, output: "late result")
    let record = try #require(try await store.snapshot().past.first?.turns.first)
    let requests = try #require(record.modelRequests)
    #expect(record.raw == "firstsecond" && requests.map { $0.response } == ["first", "second"])
    #expect(requests[0].firstTokenAt == arrival && requests[1].firstTokenAt == nil)
    #expect(requests[0].toolCalls.first?.output == "late result" && requests[1].toolCalls.isEmpty)
    #expect(requests[0].tokenUsage?.total == 5 && requests[1].tokenUsage?.total == 13)
}

@Test(.actionCatalog) func interruptedModelChainRetainsCompletedMessagesAndLosesUnsavedOutput() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let store = try journal(at: url)
    let id = UUID().uuidString
    _ = try await store.beginFixture(id: id, user: "question", system: "system", model: "fixture")
    for index in 0..<8 {
        try await store.beginModelRequest(
            .init(id: UUID().uuidString, input: "round \(index)", requestJSON: "[]"), for: id)
        if index == 7 {
            try await store.append("partial", to: id)
        } else {
            try await store.finishModelRequest(id, reason: "toolCalls")
        }
    }
    await #expect(throws: ConversationHistoryError.invalidRecord) {
        try await store.beginModelRequest(
            .init(id: UUID().uuidString, input: "excess", requestJSON: "[]"), for: id)
    }
    let record = try #require(try await journal(at: url).snapshot().current.turns.first)
    #expect(record.state == .interrupted && record.modelRequests?.count == 8 && record.response.isEmpty)
    try await store.finish(id, state: .cancelled)
    #expect(try await store.snapshot().current.turns.first?.modelRequests?.last?.state == .cancelled)
}

@Test(.actionCatalog) func requestInterfaceTimingIsImmutableAndPersistsSeparatelyFromAdmissionDate() async throws {
    let store = ConversationHistoryStore()
    let read = try await store.readCurrent()
    let id = UUID().uuidString
    _ = try await store.begin(id: id, user: "hello", request: [], expecting: read.token, model: "stub")
    try await store.beginModelRequest(
        .init(id: UUID().uuidString, input: "hello", requestJSON: "[]"), for: id)
    let start = Date(timeIntervalSinceReferenceDate: 100)
    let first = start.addingTimeInterval(0.2)
    try await store.recordModelTiming(startedAt: start, firstTokenAt: first, latency: 0.2, for: id)
    try await store.recordModelTiming(startedAt: first, firstTokenAt: first, latency: 0, for: id)
    let request = try #require(try await store.snapshot().current.turns.first?.modelRequests?.first)
    #expect(request.modelRequestStartedAt == start && request.firstTokenAt == first)
    #expect(request.firstTokenLatency == 0.2 && request.date != start)
    let encoded = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ConversationModelRequest.self, from: encoded)
    #expect(decoded.firstTokenLatency == 0.2 && decoded.modelRequestStartedAt == start)
    await #expect(throws: ConversationHistoryError.invalidRecord) {
        try await store.recordModelTiming(startedAt: start, firstTokenAt: first, latency: -1, for: id)
    }
}

@Test(.actionCatalog) func failedModelAttemptAllowsNextRequestWithoutCompletingItsTurn() async throws {
    let store = ConversationHistoryStore()
    let input = UUID().uuidString
    _ = try await store.beginFixture(id: input, user: "goal", system: "system", model: "fixture")
    try await store.beginModelRequest(
        .init(id: UUID().uuidString, input: "goal", requestJSON: "[]"), for: input)
    try await store.append("partial", to: input)
    try await store.finishModelRequest(input, reason: "error", error: "HTTP 500")
    let failed = try #require(try await store.snapshot().current.turns.first)
    #expect(failed.state == .generating)
    #expect(failed.modelRequests?.first?.state == .failed)
    #expect(failed.modelRequests?.first?.error == "HTTP 500")
    try await store.beginModelRequest(
        .init(id: UUID().uuidString, input: "HTTP 500", requestJSON: "[]"), for: input)
    try await store.append("recovered", to: input)
    try await store.finishModelRequest(input, reason: "stop")
    try await store.finish(input, state: .completed)
    let completed = try #require(try await store.snapshot().current.turns.first)
    #expect(completed.state == .completed)
    #expect(completed.modelRequests?.map(\.state) == [.failed, .completed])
    #expect(completed.modelRequests?.last?.error == nil)
}

@Test(.actionCatalog) func historyOrderPreservesInterleavedInputContinuations() async throws {
    let store = ConversationHistoryStore()
    let first = UUID().uuidString
    let second = UUID().uuidString
    let token = try await store.readCurrent().token
    _ = try await store.begin(id: first, user: "A", request: [], expecting: token, model: "stub")
    try await store.beginModelRequest(
        .init(id: UUID().uuidString, input: "A1", requestJSON: "[]"), for: first)
    try await store.append("A1 output", to: first)
    try await store.finishModelRequest(first, reason: "stop")
    let next = try await store.readCurrent().token
    _ = try await store.begin(id: second, user: "B", request: [], expecting: next, model: "stub")
    try await store.beginModelRequest(
        .init(id: UUID().uuidString, input: "B1", requestJSON: "[]"), for: second)
    try await store.append("B1 output", to: second)
    try await store.finish(second, state: .completed)
    try await store.beginModelRequest(
        .init(id: UUID().uuidString, input: "A2", requestJSON: "[]"), for: first)
    try await store.append("A2 output", to: first)
    try await store.finish(first, state: .completed)
    let current = try await store.snapshot().current
    let ordered = try current.indexedHistory().compactMap { item -> String? in
        if case .request(_, let request) = item { return request.input }
        return nil
    }
    #expect(ordered == ["A1", "B1", "A2"])
    let rows = try AgentChatContextBuilder.request(
        system: "s", user: "next", conversation: current, templates: AgentPrompts.load(named: "Assistant"))
    #expect(rows.filter { $0.role == .assistant }.map(\.content) == ["A1 output", "B1 output", "A2 output"])
    let result =
        try JSONSerialization.jsonObject(
            with: Data(
                try await HistoryQueryService(store: store).read(reference: .init(id: current.id), offset: 1, limit: 2)
                    .utf8))
        as? [String: Any]
    let items = try #require(result?["items"] as? [[String: Any]])
    #expect(items.count == 2 && (items[0]["user"] as? [String: Any])?["value"] as? String == "B1")
}

@Test(.actionCatalog) func assistantFileCheckpointRestoresBeforeSkillInitializationAndIgnoresOldFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let scope = UUID().uuidString
    let first = try AgentContextRepository(
        agent: .assistant, scope: scope, state: AssistantContextState()
    )
    let firstStore = try fixtureAssistantStore(repository: first, directory: root)
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: HistoryModel("<express emotion=\"happy\"/>"), conversations: firstStore, context: first)
    try await agent.start()
    try await agent.receive(
        .init(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("remember this")))
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    while let output = try await outputs.next() { if output.output == .control("agent.finished") { break } }
    await agent.stop()
    // Deliberately corrupt obsolete files: the new path must not read them.
    try Data("obsolete invalid data".utf8).write(to: root.appendingPathComponent("assistant.history-v2.context.json"))
    try Data("obsolete invalid data".utf8).write(to: root.appendingPathComponent("assistant.context.json"))
    let second = try AgentContextRepository(
        agent: .assistant, scope: scope, state: AssistantContextState()
    )
    let secondStore = try fixtureAssistantStore(repository: second, directory: root)
    let restarted = try AssistantAgent(
        stateContext: try publicStateFixture(), chat: HistoryModel("unused"), conversations: secondStore,
        context: second)
    try await restarted.start()
    let restored = try await second.snapshot()
    #expect(restored.state.history.current.turns.first?.user == "remember this")
    #expect(restored.state.history.current.turns.first?.response == "<express emotion=\"happy\"/>")
    #expect(restored.state.history.current.turns.first?.state == .completed)
    #expect(restored.records.isEmpty && restored.consumedBatches.isEmpty && restored.state.history.past.isEmpty)
    #expect(restored.state.skillState?.loaded.isEmpty == false)
    await restarted.stop()
}

@Test(.actionCatalog) func historyRejectsInvalidCacheUsageWithoutChangingEvidence() async throws {
    let store = ConversationHistoryStore()
    let id = UUID().uuidString
    _ = try await store.beginFixture(id: id, user: "usage", system: "system", model: "fixture")
    let usage = ConversationTokenUsage(input: 12, generated: 2, total: 14, cachedInput: 8, cacheWriteInput: 2)
    try await store.recordTokenUsage(usage, for: id)
    await #expect(throws: ConversationHistoryError.invalidRecord) {
        try await store.recordTokenUsage(
            .init(input: 12, generated: 2, total: 14, cachedInput: 11, cacheWriteInput: 2), for: id)
    }
    #expect(try await store.snapshot().current.turns.first?.tokenUsage == usage)
    let legacy = try JSONDecoder().decode(
        ConversationTokenUsage.self, from: Data(#"{"input":12,"generated":2,"total":14}"#.utf8))
    #expect(legacy.cachedInput == nil && legacy.cacheWriteInput == nil)
}
