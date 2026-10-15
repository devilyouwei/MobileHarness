import Actions
import AgentCore
import Agents
import BehaviorAssembly
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import Storage
import StorageChat
import Testing

private func historyRequest(_ path: String, _ arguments: [String: String]) -> ActionInvocation {
    ActionInvocation(
        tool: ToolRequest(id: UUID().uuidString, toolPath: path, arguments: arguments),
        context: .init(
            source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString))
}
private func historyObject(_ json: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}
private func historyTurn(_ store: ConversationHistoryStore, user: String, response: String) async throws {
    let read = try await store.readCurrent()
    let id = UUID().uuidString
    _ = try await store.begin(id: id, user: user, request: [], expecting: read.token, model: "fixture")
    try await store.beginModelRequest(.init(id: UUID().uuidString, input: user, requestJSON: "[]"), for: id)
    try await store.append(response, to: id)
    try await store.finishModelRequest(id, reason: "stop")
    try await store.finish(id, state: .completed)
}

@Test(.actionCatalog) func historyToolsPageRawRecordsWithoutMutationOrReplay() async throws {
    let store = ConversationHistoryStore()
    try await historyTurn(store, user: "past", response: "<express emotion=\"happy\"/>")
    let archived = try #require(try await store.startNew())
    try await store.setTitle("Saved summary", for: archived.id)
    try await historyTurn(store, user: "current", response: "reply")
    let history = HistoryQueryService(store: store)
    let readFence = try await store.readCurrent()
    let first = try historyObject(
        await HistoryActions.list(
            invocation: historyRequest("History.Conversation.list", ["offset": "0", "limit": "1"]), using: history))
    let items = try #require(first["items"] as? [[String: Any]])
    #expect(items.count == 1 && items[0]["archived"] as? Bool == false)
    #expect(items[0]["createdAt"] is String)
    #expect(first["total"] as? Int == 2 && first["nextOffset"] as? Int == 1)
    let result = try await HistoryActions.read(
        invocation: historyRequest(
            "History.Conversation.read",
            [
                "id": archived.id, "offset": "0", "limit": "1",
            ]), using: history)
    let turns = try #require(try historyObject(result)["items"] as? [[String: Any]])
    let response = try #require(turns[0]["response"] as? [String: Any])
    #expect(response["value"] as? String == "<express emotion=\"happy\"/>")
    #expect(response["truncated"] as? Bool == false)
    #expect(try await store.readCurrent().token == readFence.token)
    #expect(result.utf8.count <= 1800)
    #expect(try historyObject(await history.list(offset: 64, limit: 5))["items"] as? [String] == [])
}

@Test(.actionCatalog) func historyToolsReportTruncationAndRejectMissingOrOversizedResults() async throws {
    let store = ConversationHistoryStore()
    try await historyTurn(store, user: String(repeating: "中", count: 100), response: String(repeating: "答", count: 200))
    let read = try await store.readCurrent()
    let history = HistoryQueryService(store: store)
    let result = try historyObject(await history.read(reference: .init(id: read.current.id), offset: 0, limit: 2))
    let turns = try #require(result["items"] as? [[String: Any]])
    let response = try #require(turns[0]["response"] as? [String: Any])
    #expect(response["truncated"] as? Bool == true)
    #expect((response["value"] as? String)?.utf8.count == 159)
    await #expect(throws: HistoryQueryError.missingConversation) {
        try await history.read(reference: .init(id: "dialog_999999"), offset: 0, limit: 1)
    }
    let crowded = ConversationHistoryStore()
    for _ in 0..<2 {
        try await historyTurn(
            crowded, user: String(repeating: "\u{1}", count: 80), response: String(repeating: "\u{1}", count: 160))
    }
    let crowdedID = try await crowded.readCurrent().current.id
    await #expect(throws: HistoryQueryError.resultTooLarge) {
        try await HistoryQueryService(store: crowded).read(reference: .init(id: crowdedID), offset: 0, limit: 2)
    }
}

private actor HistoryQueryProbe: HistoryQueryCapability {
    var calls = 0
    func list(offset: Int, limit: Int) async throws -> String {
        calls += 1
        return "{}"
    }
    func read(reference: HistoryConversationReference, offset: Int, limit: Int) async throws -> String {
        calls += 1
        return "{}"
    }
}
@Test(.actionCatalog) func historyToolsValidateArgumentsBeforeQuerying() async throws {
    let probe = HistoryQueryProbe()
    for arguments in [
        ["offset": "-1", "limit": "1"], ["offset": "0", "limit": "6"], ["offset": "0"],
        ["offset": "0", "limit": "1", "extra": "x"],
    ] {
        await #expect(throws: (any Error).self) {
            try await HistoryActions.list(
                invocation: historyRequest("History.Conversation.list", arguments), using: probe)
        }
    }
    await #expect(throws: (any Error).self) {
        try await HistoryActions.read(
            invocation: historyRequest("History.Conversation.read", ["id": "invalid", "offset": "0", "limit": "1"]),
            using: probe)
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await HistoryActions.list(
            invocation: historyRequest("History.Conversation.list", ["offset": "0", "limit": "1"]), using: probe)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await probe.calls == 0)
}

@Test(.actionCatalog) func historyDeclarationsResolveNativeStringArgumentsAndReturnCorrelatedResults() async throws {
    let configuration = try AgentConfigurations.load(named: "Memory")
    let id = UUID().uuidString
    let call = try ToolCallParser.parse(
        id: id, alias: "History.list", argumentsJSON: Data("{\"offset\":\"0\",\"limit\":\"1\"}".utf8),
        capabilities: configuration.capabilities)
    #expect(call.toolPath == "History.Conversation.list" && call.id == id)
    let registry = try BehaviorAssembly(capabilityModules: [
        HistoryModule(
            history: HistoryQueryService(store: ConversationHistoryStore()),
            mutations: HistoryMutationService(
                store: ConversationHistoryStore(), summarizeTitle: { _ in "Unused fixture title" })
        )
    ]).tools
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture"))
    let envelope = OutputEnvelope(source: .assistant, input: input, output: .toolCall(call))
    let response = try await ToolExecutor(registry: registry).execute(call, envelope: envelope)
    #expect(response?.callID == id && response?.isError == false)
}

@Test(.actionCatalog) func historyCanonicalIDReadsAfterArchiveAndReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConversationHistoryStore(records: try testConversationRecords(directory: directory))
    try await historyTurn(store, user: "recorded input", response: "actual answer")
    let history = HistoryQueryService(store: store)
    let listed = try #require(try historyObject(await history.list(offset: 0, limit: 1))["items"] as? [[String: Any]])
    let id = try #require(listed[0]["id"] as? String)
    #expect(id.hasPrefix("dialog_"))
    #expect(listed[0]["ref"] == nil)
    _ = try await store.startNew()
    let reopened = ConversationHistoryStore(records: try testConversationRecords(directory: directory))
    let reader = HistoryQueryService(store: reopened)
    let result = try await HistoryActions.read(
        invocation: historyRequest("History.Conversation.read", ["id": id, "offset": "0", "limit": "2"]),
        using: reader)
    let items = try #require(try historyObject(result)["items"] as? [[String: Any]])
    #expect((items[0]["response"] as? [String: Any])?["value"] as? String == "actual answer")
    await #expect(throws: HistoryQueryError.missingConversation) {
        try await reader.read(reference: .init("dialog_9223372036854775807"), offset: 0, limit: 1)
    }
}

@Test(.actionCatalog) func historyReferenceValidationRejectsNoncanonicalIDsBeforeQuerying() async throws {
    let probe = HistoryQueryProbe()
    for id in ["conversation_0", "conversation_01", "task_1", "current", " conversation_1", "conversation_１"] {
        await #expect(throws: ActionArguments.ValidationError.self) {
            try await HistoryActions.read(
                invocation: historyRequest("History.Conversation.read", ["id": id, "offset": "0", "limit": "1"]),
                using: probe)
        }
    }
    #expect(await probe.calls == 0)
}
