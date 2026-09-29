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
    let request = try await first.begin(id: id, user: original, system: "system", model: "gpt-4.1")
    #expect(request.request.last?.content == original)
    try await first.append("<wait>\n", to: id)
    try await first.append("hello &amp; world", to: id)
    let recovered = try await journal(at: url).snapshot()
    let turn = try #require(recovered.current.turns.first)
    #expect(turn.user == original && recovered.current.title == original)
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
        _ = try await store.begin(id: id, user: "question \(index)", system: "system", model: "fixture")
        try await store.append("answer \(index)", to: id)
        try await store.finish(id, state: .completed, reason: "stop")
    }
    let failed = UUID()
    _ = try await store.begin(id: failed, user: "failed question", system: "system", model: "fixture")
    try await store.append("<wait/>", to: failed)
    try await store.finish(failed, state: .failed, error: "bad syntax")
    let id = UUID()
    let request = try await store.begin(id: id, user: "next", system: "new system", model: "fixture")
    #expect(request.request.count == 22)
    #expect(request.request[1].content == "question 2")
    #expect(request.request[20].content == "answer 11")
    #expect(!request.request.contains { $0.content == "<wait/>" })
    await #expect(throws: ConversationHistoryError.busy) { try await store.startNew() }
    try await store.finish(id, state: .cancelled)
    let past = try #require(try await store.startNew())
    #expect(past.turns.count == 14 && past.archivedAt != nil)
    let fresh = try await store.begin(id: UUID(), user: "fresh", system: "system", model: "fixture")
    #expect(fresh.request.count == 2)
    try await store.setTitle("A summarized topic", for: past.id)
    let snapshot = try await store.snapshot()
    #expect(snapshot.current.title == "fresh" && snapshot.current.summaryTitle == nil)
    #expect(snapshot.past.first?.title == "A summarized topic")
    try await store.deleteArchived(past.id)
    #expect(try await store.snapshot().past.isEmpty)
}

@Test func rawOverflowPreservesPrefixAndAdmissionFailureDoesNotOverwriteJournal() async throws {
    let store = ConversationHistoryStore()
    let id = UUID()
    _ = try await store.begin(id: id, user: "original", system: "system", model: "fixture")
    let prefix = String(repeating: "x", count: 262144)
    try await store.append(prefix, to: id)
    await #expect(throws: ConversationHistoryError.capacityExceeded) { try await store.append("x", to: id) }
    try await store.finish(id, state: .failed, error: "overflow")
    #expect(try await store.snapshot().current.turns.first?.raw == prefix)
    await #expect(throws: ConversationHistoryError.invalidRecord) {
        try await store.begin(id: UUID(), user: String(repeating: "x", count: 4097), system: "system", model: "fixture")
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
    var iterator = agent.outputs.makeAsyncIterator()
    let output = try #require(await iterator.next())
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
    _ = try await store.begin(id: id, user: "Compare channel and wait", system: "system", model: "fixture")
    try await store.append("Some answer", to: id)
    try await store.finish(id, state: .completed)
    let archived = try #require(try await store.startNew())
    let model = HistoryModel("Channel and wait coordination")
    let title = try await ConversationTitleGenerator.summarize(archived, using: model)
    try await store.setTitle(title, for: archived.id)
    #expect(try await store.snapshot().past.first?.title == title)
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
    _ = try await firstStore.begin(id: previousID, user: "previous user", system: "old system", model: "fixture")
    try await firstStore.append("<express emotion=\"happy\"/>", to: previousID)
    try await firstStore.finish(previousID, state: .completed, reason: "stop")
    let model = HistoryModel("<express emotion=\"smile\"/>")
    let restored = try journal(at: url)
    let agent = try AssistantAgent(chat: model, conversations: restored)
    try await agent.start()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("continue")))
    var iterator = agent.outputs.makeAsyncIterator()
    let action = try #require(await iterator.next())
    #expect(action.output == .actionCall(expectedActionCall(name: "express", parameters: ["emotion": "smile"])))
    #expect(await iterator.next()?.output == .control("assistant.finished"))
    let request = try #require(await model.requests.first)
    #expect(request.messages.count == 4)
    #expect(request.messages[1].content == "previous user")
    #expect(request.messages[2].content == "<express emotion=\"happy\"/>")
    await agent.stop()
    #expect(try await restored.snapshot().current.turns.count == 2)
}

@Test func failedDurableWriteLeavesPriorTurnAndRequestUnchanged() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let store = ConversationHistoryStore(document: try LocalDocumentStore(url: url, maximumBytes: 2048))
    let id = UUID()
    _ = try await store.begin(id: id, user: "preserve this", system: "system", model: "fixture")
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
    _ = try await store.begin(id: id, user: "input", system: "system", model: "fixture")
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
    let record = try await store.begin(id: UUID(), user: "hello", system: "system", model: "fixture")
    #expect(record.maximumOutputTokens == nil)
    let encoded = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(ConversationRecord.self, from: encoded).maximumOutputTokens == nil)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy["maximumOutputTokens"] = 256
    let restored = try JSONDecoder().decode(
        ConversationRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(restored.maximumOutputTokens == 256)
}
