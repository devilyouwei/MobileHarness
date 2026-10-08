import AgentCore
import Agents
import Foundation
import ModelKit
import Storage
import StorageChat
import Testing

private func journal(at url: URL) throws -> ConversationHistoryStore {
    ConversationHistoryStore(
        document: try LocalDocumentStore(
            url: url, maximumBytes: ConversationHistoryStore.maximumBytes))
}

@Test func conversationJournalRestoresRawRequestAndMarksInterruptedGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let first = try journal(at: url)
    let id = UUID()
    let original = "  用户原文\n串行执行  "
    let request = try await first.beginFixture(id: id, user: original, system: "system", model: "gpt-4.1")
    #expect(request.request.last?.content == original)
    try await first.append("<wait>\n", to: id)
    try await first.append("hello &amp; world", to: id)
    let recovered = try await journal(at: url).snapshot()
    let turn = try #require(recovered.current.turns.first)
    #expect(turn.user == original && recovered.current.turns.last?.user == original)
    #expect(turn.fragments == ["<wait>\n", "hello &amp; world"])
    #expect(turn.raw == "<wait>\nhello &amp; world")
    #expect(turn.request == request.request)
    #expect(turn.state == .interrupted)
    #expect(recovered.current.summaryTitle == nil)
}

@Test func contextUsesTenCompleteRoundsAndNewConversationIsIsolated() async throws {
    let store = ConversationHistoryStore()
    for index in 0..<12 {
        let id = UUID()
        _ = try await store.beginFixture(id: id, user: "question \(index)", system: "system", model: "fixture")
        try await store.append("answer \(index)", to: id)
        try await store.finish(id, state: .completed, reason: "stop")
    }
    let failed = UUID()
    _ = try await store.beginFixture(id: failed, user: "failed question", system: "system", model: "fixture")
    try await store.append("<wait/>", to: failed)
    try await store.finish(failed, state: .failed, error: "bad syntax")
    let id = UUID()
    let request = try await store.beginFixture(id: id, user: "next", system: "new system", model: "fixture")
    #expect(request.request.count == 22)
    #expect(request.request[1].content == "question 2")
    #expect(request.request[20].content == "answer 11")
    #expect(!request.request.contains { $0.content == "<wait/>" })
    await #expect(throws: ConversationHistoryError.busy) { try await store.startNew() }
    try await store.finish(id, state: .cancelled)
    let past = try #require(try await store.startNew())
    #expect(past.turns.count == 14 && past.archivedAt != nil)
    let fresh = try await store.beginFixture(id: UUID(), user: "fresh", system: "system", model: "fixture")
    #expect(fresh.request.count == 2)
    try await store.setTitle("A summarized topic", for: past.id)
    let snapshot = try await store.snapshot()
    #expect(snapshot.current.turns.last?.user == "fresh" && snapshot.current.summaryTitle == nil)
    #expect(snapshot.past.first?.summaryTitle == "A summarized topic")
    try await store.deleteArchived(past.id)
    #expect(try await store.snapshot().past.isEmpty)
}

@Test func rawOverflowPreservesPrefixAndAdmissionFailureDoesNotOverwriteJournal() async throws {
    let store = ConversationHistoryStore()
    let id = UUID()
    _ = try await store.beginFixture(id: id, user: "original", system: "system", model: "fixture")
    let prefix = String(repeating: "x", count: 262144)
    try await store.append(prefix, to: id)
    await #expect(throws: ConversationHistoryError.capacityExceeded) { try await store.append("x", to: id) }
    try await store.finish(id, state: .failed, error: "overflow")
    #expect(try await store.snapshot().current.turns.first?.raw == prefix)
    await #expect(throws: ConversationHistoryError.invalidRecord) {
        try await store.beginFixture(
            id: UUID(), user: String(repeating: "x", count: 4097), system: "system", model: "fixture")
    }
    #expect(try await store.snapshot().current.turns.count == 1)
}

private actor HistoryModel: ChatCapability {
    let availability: CapabilityAvailability = .available
    let text: String
    let leaveOpen: Bool
    var requests: [ChatRequest] = []
    init(_ text: String, leaveOpen: Bool = false) {
        self.text = text
        self.leaveOpen = leaveOpen
    }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text(text))
        if !leaveOpen {
            try pair.emitter.yield(.finished(.stop))
            pair.emitter.finish()
        }
        return pair.session
    }
}

@Test func assistantRecordsMalformedOutputBeforeParsingAndContextSurvivesNewInstance() async throws {
    let store = ConversationHistoryStore()
    let model = HistoryModel("<wait/>")
    let agent = try AssistantAgent(chat: model, conversations: store)
    try await agent.start()
    let input = AgentInput(sessionID: UUID(), payload: .text("请串行"))
    try await agent.receive(input)
    var iterator = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    let output = try #require(try await iterator.next())
    guard case .control(let message) = output.output else {
        Issue.record("Expected error")
        return
    }
    #expect(message.hasPrefix("assistant.error:"))
    let turn = try #require(try await store.snapshot().current.turns.first)
    #expect(turn.user == "请串行" && turn.raw == "<wait/>" && turn.state == .failed)
    #expect(turn.error != nil)
    await agent.stop()
}

@Test func cancellationPersistsReceivedTextBeforeStoppingProducer() async throws {
    let store = ConversationHistoryStore()
    let agent = try AssistantAgent(chat: HistoryModel("partial", leaveOpen: true), conversations: store)
    try await agent.start()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("original")))
    for _ in 0..<10000 {
        if let snapshot = try? await store.snapshot(), snapshot.current.turns.first?.raw == "partial" { break }
        await Task.yield()
    }
    await agent.stop()
    let turn = try #require(try await store.snapshot().current.turns.first)
    #expect(turn.raw == "partial" && turn.state == .cancelled)
}

@Test func titleGenerationIsSeparateAndStoredOnlyOnArchivedConversation() async throws {
    let store = ConversationHistoryStore()
    let id = UUID()
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

@Test func assistantLoadsSavedContextInANewInstanceWithoutReplayingActions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let firstStore = try journal(at: url)
    let previousID = UUID()
    _ = try await firstStore.beginFixture(id: previousID, user: "previous user", system: "old system", model: "fixture")
    try await firstStore.append("<express emotion=\"happy\"/>", to: previousID)
    try await firstStore.finish(previousID, state: .completed, reason: "stop")
    let model = HistoryModel("<express emotion=\"smile\"/>")
    let restored = try journal(at: url)
    let agent = try AssistantAgent(chat: model, conversations: restored)
    try await agent.start()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("continue")))
    var iterator = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    let action = try #require(try await iterator.next())
    #expect(action.output == .actionCall(expectedActionCall(name: "express", parameters: ["emotion": "smile"])))
    #expect(try await iterator.next()?.output == .control("assistant.finished"))
    let request = try #require(await model.requests.first)
    #expect(request.messages.count == 4)
    #expect(request.messages[1].content == "previous user")
    #expect(request.messages[2].content == "<express emotion=\"happy\"/>")
    let savedRequest = try #require(try await restored.snapshot().current.turns.last?.request)
    #expect(request.messages.map(\.content) == savedRequest.map(\.content))
    await agent.stop()
    #expect(try await restored.snapshot().current.turns.count == 2)
}

@Test func failedDurableWriteLeavesPriorTurnAndRequestUnchanged() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let store = ConversationHistoryStore(document: try LocalDocumentStore(url: url, maximumBytes: 2048))
    let id = UUID()
    _ = try await store.beginFixture(id: id, user: "preserve this", system: "system", model: "fixture")
    try await store.append("prefix", to: id)
    await #expect(throws: DocumentStorageError.capacityExceeded) {
        try await store.append(String(repeating: "z", count: 3000), to: id)
    }
    try await store.finish(id, state: .failed, error: "disk capacity rejected the new fragment")
    let restored = try await journal(at: url).snapshot()
    #expect(restored.current.turns.first?.raw == "prefix")
    #expect(restored.current.turns.first?.user == "preserve this")
    #expect(restored.current.turns.first?.state == .failed)
}

@Test func failedTerminalWriteDoesNotLeaveAStoppedProducerBlockingNewConversation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConversationHistoryStore(
        document: try LocalDocumentStore(
            url: directory.appendingPathComponent("history.json"), maximumBytes: 2048))
    let id = UUID()
    _ = try await store.beginFixture(id: id, user: "input", system: "system", model: "fixture")
    await #expect(throws: DocumentStorageError.capacityExceeded) {
        try await store.finish(id, state: .failed, error: String(repeating: "e", count: 4000))
    }
    #expect(try await store.snapshot().current.turns.first?.state == .interrupted)
    let archived = try #require(try await store.startNew())
    #expect(archived.turns.first?.error?.contains("could not be saved") == true)
    #expect(try await store.snapshot().current.turns.isEmpty)
}

@Test func conversationTokenBudgetPreservesOldExplicitValuesAndNewDefault() async throws {
    let store = ConversationHistoryStore()
    let record = try await store.beginFixture(id: UUID(), user: "hello", system: "system", model: "fixture")
    #expect(record.maximumOutputTokens == nil)
    let encoded = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(ConversationRecord.self, from: encoded).maximumOutputTokens == nil)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy["maximumOutputTokens"] = 256
    let restored = try JSONDecoder().decode(
        ConversationRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(restored.maximumOutputTokens == 256)
}

@Test func toolJournalPersistsInputsUsageAndLateArchivedOutcomes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let store = try journal(at: url)
    let id = UUID()
    _ = try await store.beginFixture(id: id, user: "打开摄像头", system: "system", model: "fixture")
    try await store.recordToolDefinitions(["camera declaration"], for: id)
    let call = ConversationToolCall(
        id: UUID(), providerID: "provider-1", name: "Camera.open", argumentsJSON: "{}")
    try await store.recordToolCall(call, for: id)
    try await store.recordTokenUsage(ConversationTokenUsage(input: 12, generated: 4, total: 16), for: id)
    try await store.finish(id, state: .completed, reason: "toolCalls")
    _ = try await store.startNew()
    try await store.recordToolOutcome(call.id, for: id, state: .completed)
    let restored = try #require(try await journal(at: url).snapshot().past.first?.turns.first)
    #expect(restored.toolDefinitions == ["camera declaration"])
    #expect(restored.tokenUsage == ConversationTokenUsage(input: 12, generated: 4, total: 16))
    let result = try #require(restored.toolCalls?.first)
    #expect(result.providerID == "provider-1" && result.argumentsJSON == "{}" && result.state == .completed)
    #expect(result.output == nil)
    try await store.recordToolOutcome(call.id, for: id, state: .failed, output: "permission denied", error: "fixture")
    #expect(try await store.snapshot().past.first?.turns.first?.toolCalls?.first?.output == "permission denied")
    // An internal UI Tool or non-journal input does not create a model-call record.
    try await store.recordToolOutcome(UUID(), for: UUID(), state: .completed)
}

@Test func oldConversationRecordDecodesWithoutToolOrUsageFields() async throws {
    let store = ConversationHistoryStore()
    let record = try await store.beginFixture(id: UUID(), user: "legacy", system: "system", model: "fixture")
    let restored = try JSONDecoder().decode(ConversationRecord.self, from: JSONEncoder().encode(record))
    #expect(restored.toolCalls == nil && restored.toolDefinitions == nil && restored.tokenUsage == nil)
}

private struct NativeCameraHistoryChat: ChatCapability {
    var availability: CapabilityAvailability { .available }
    var supportsToolCalls: Bool { true }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        #expect(request.maximumOutputTokens == nil)
        #expect(request.tools.contains { $0.name == "Camera.open" })
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if request.messages.last?.role == .tool {
            try pair.emitter.yield(.text("<express emotion=\"smile\"/>"))
            try pair.emitter.yield(.finished(.stop))
            pair.emitter.finish()
            return pair.session
        }
        try pair.emitter.yield(.text("<express emotion=\"smile\"/>"))
        try pair.emitter.yield(
            .toolCall(ChatToolCall(id: "cloud-camera", name: "Camera.open", argumentsJSON: "{}")))
        try pair.emitter.yield(.usage(try ChatTokenUsage(input: 100, generated: 20, total: 120)))
        try pair.emitter.yield(.finished(.toolCalls))
        pair.emitter.finish()
        return pair.session
    }
}

@Test func assistantJournalsMixedActionNativeToolAndUsageWithRuntimeCorrelation() async throws {
    let store = ConversationHistoryStore()
    let agent = try AssistantAgent(chat: NativeCameraHistoryChat(), conversations: store)
    try await agent.start()
    let input = AgentInput(sessionID: UUID(), payload: .text("打开摄像头并微笑"))
    try await agent.receive(input)
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    guard case .actionCall = try await outputs.next()?.output else {
        Issue.record("Missing XML action")
        return
    }
    guard case .toolCall(let call) = try await outputs.next()?.output else {
        Issue.record("Missing native tool")
        return
    }
    #expect(call.toolPath == "Camera.Capture.open")
    let feedbackPayload = InputPayload.toolResult(.init(callID: call.id, value: "completed"))
    try await agent.receive(
        AgentInput(
            sessionID: input.sessionID, payload: feedbackPayload,
            metadata: InputMetadata(
                payload: feedbackPayload, source: "runtime", origin: .runtime, rootID: input.metadata.rootID,
                parentID: input.id)))
    while let output = try await outputs.next() { if output.output == .control("assistant.finished") { break } }
    let record = try #require(try await store.snapshot().current.turns.first)
    #expect(record.state == .completed && record.finishReason == "stop")
    #expect(record.toolCalls?.first?.id == call.id)
    #expect(record.toolCalls?.first?.providerID == "cloud-camera")
    #expect(record.toolCalls?.first?.state == .completed)
    #expect(record.tokenUsage?.generated == 20)
    #expect(record.toolDefinitions?.contains { $0.contains("Camera.open") } == true)
    await agent.stop()
}

@Test func concurrentGenerationAndToolOutcomesPreserveBothDurableUpdates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let store = try journal(at: url)
    let id = UUID()
    _ = try await store.beginFixture(id: id, user: "concurrent fixture", system: "system", model: "fixture")
    let call = ConversationToolCall(id: UUID(), providerID: "cloud", name: "Camera.close", argumentsJSON: "{}")
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
    #expect(Set(restored.fragments) == Set((0..<8).map { "fragment-\($0)" }))
    #expect(restored.toolCalls?.first?.state == .completed)
    #expect(restored.tokenUsage?.total == 3)
}

extension ConversationHistoryStore {
    fileprivate func beginFixture(id: UUID, user: String, system: String, model: String) async throws
        -> ConversationRecord
    {
        let read = try await readCurrent()
        let request = ConversationContextBuilder.request(system: system, user: user, conversation: read.current)
        return try await begin(id: id, user: user, request: request, expecting: read.token, model: model)
    }
}

@Test func historyRejectsStaleAndForeignReadTokens() async throws {
    let store = ConversationHistoryStore()
    let read = try await store.readCurrent()
    let request = [ConversationMessage(role: .user, content: "exact caller payload")]
    let id = UUID()
    let record = try await store.begin(id: id, user: "raw", request: request, expecting: read.token, model: "fixture")
    #expect(record.request == request)
    try await store.finish(id, state: .completed)
    await #expect(throws: ConversationHistoryError.conflict) {
        try await store.begin(id: UUID(), user: "raw", request: request, expecting: read.token, model: "fixture")
    }
    let beforeArchive = try await store.readCurrent()
    _ = try await store.startNew()
    await #expect(throws: ConversationHistoryError.conflict) {
        try await store.begin(
            id: UUID(), user: "raw", request: request, expecting: beforeArchive.token, model: "fixture")
    }
    let other = try await ConversationHistoryStore().readCurrent()
    await #expect(throws: ConversationHistoryError.conflict) {
        try await store.begin(id: UUID(), user: "raw", request: request, expecting: other.token, model: "fixture")
    }
    #expect(try await store.snapshot().current.turns.isEmpty)
}

@Test func assistantConflictDoesNotCallModelOrWriteNewTurn() async throws {
    let store = ConversationHistoryStore()
    let previous = UUID()
    _ = try await store.beginFixture(id: previous, user: "previous", system: "system", model: "fixture")
    try await store.finish(previous, state: .completed)
    let model = HistoryModel("should not run")
    let agent = try AssistantAgent(
        chat: model, conversations: store,
        modelName: {
            _ = try await store.startNew()
            return "fixture"
        })
    try await agent.start()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("next")))
    var iterator = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    guard case .control(let message) = try await iterator.next()?.output else {
        Issue.record("Expected admission error")
        await agent.stop()
        return
    }
    #expect(message.hasPrefix("assistant.error:"))
    #expect(await model.requests.isEmpty)
    #expect(try await store.snapshot().current.turns.isEmpty)
    await agent.stop()
}

@Test func assistantPersistenceFailureDoesNotCallModel() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConversationHistoryStore(
        document: try LocalDocumentStore(
            url: directory.appendingPathComponent("history.json"), maximumBytes: 128))
    let model = HistoryModel("should not run")
    let agent = try AssistantAgent(chat: model, conversations: store)
    try await agent.start()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("next")))
    var iterator = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    guard case .control(let message) = try await iterator.next()?.output else {
        Issue.record("Expected persistence error")
        await agent.stop()
        return
    }
    #expect(message.hasPrefix("assistant.error:"))
    #expect(await model.requests.isEmpty)
    #expect(try await store.snapshot().current.turns.isEmpty)
    await agent.stop()
}

@Test func modelRequestJournalKeepsFirstTokenUsageAndLateOutcomesWithTheirRequest() async throws {
    let store = ConversationHistoryStore()
    let id = UUID()
    _ = try await store.beginFixture(id: id, user: "question", system: "system", model: "fixture")
    let first = ConversationModelRequest(id: UUID(), input: "question", requestJSON: "[]")
    try await store.beginModelRequest(first, for: id)
    let arrival = first.date.addingTimeInterval(0.125)
    try await store.recordFirstToken(at: arrival, for: id)
    try await store.recordFirstToken(at: arrival.addingTimeInterval(1), for: id)
    try await store.append("first", to: id)
    let call = ConversationToolCall(id: UUID(), providerID: "provider", name: "inspect", argumentsJSON: "{}")
    try await store.recordToolCall(call, for: id)
    try await store.recordTokenUsage(.init(input: 2, generated: 3, total: 5), for: id)
    try await store.finishModelRequest(id, reason: "toolCalls")
    try await store.beginModelRequest(.init(id: UUID(), input: "result", requestJSON: "[]"), for: id)
    try await store.append("second", to: id)
    try await store.recordTokenUsage(.init(input: 6, generated: 7, total: 13), for: id)
    try await store.finishModelRequest(id, reason: "stop")
    try await store.finish(id, state: .completed)
    _ = try await store.startNew()
    try await store.recordToolOutcome(call.id, for: id, state: .completed, output: "late result")
    let record = try #require(try await store.snapshot().past.first?.turns.first)
    let requests = try #require(record.modelRequests)
    #expect(record.raw == "firstsecond" && requests.map { $0.fragments.joined() } == ["first", "second"])
    #expect(requests[0].firstTokenAt == arrival && requests[1].firstTokenAt == nil)
    #expect(requests[0].toolCalls.first?.output == "late result" && requests[1].toolCalls.isEmpty)
    #expect(requests[0].tokenUsage?.total == 5 && requests[1].tokenUsage?.total == 13)
}

@Test func interruptedModelRequestsRetainPartialOutputAndRequestAdmissionIsBounded() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let store = try journal(at: url)
    let id = UUID()
    _ = try await store.beginFixture(id: id, user: "question", system: "system", model: "fixture")
    for index in 0..<4 {
        try await store.beginModelRequest(.init(id: UUID(), input: "round \(index)", requestJSON: "[]"), for: id)
        if index == 3 {
            try await store.append("partial", to: id)
        } else {
            try await store.finishModelRequest(id, reason: "toolCalls")
        }
    }
    await #expect(throws: ConversationHistoryError.invalidRecord) {
        try await store.beginModelRequest(.init(id: UUID(), input: "excess", requestJSON: "[]"), for: id)
    }
    let record = try #require(try await journal(at: url).snapshot().current.turns.first)
    #expect(record.state == .interrupted && record.modelRequests?.last?.state == .interrupted)
    #expect(record.modelRequests?.last?.fragments == ["partial"])
    #expect(record.modelRequests?.first?.state == .completed)
    try await store.finish(id, state: .cancelled)
    #expect(try await store.snapshot().current.turns.first?.modelRequests?.last?.state == .cancelled)
}
