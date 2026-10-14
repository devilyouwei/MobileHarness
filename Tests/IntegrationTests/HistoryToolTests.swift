import Actions
import AgentCore
import Agents
import BehaviorAssembly
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import StorageChat
import Testing

private func historyRequest(_ path: String, _ arguments: [String: String]) -> ActionInvocation {
    ActionInvocation(
        tool: ToolRequest(toolPath: path, arguments: arguments),
        context: .init(source: "fixture", sessionID: UUID(), inputID: UUID()))
}
private func historyObject(_ json: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}
private func historyTurn(_ store: ConversationHistoryStore, user: String, response: String) async throws {
    let read = try await store.readCurrent()
    let id = UUID()
    _ = try await store.begin(id: id, user: user, request: [], expecting: read.token, model: "fixture")
    try await store.beginModelRequest(.init(id: UUID(), input: user, requestJSON: "[]"), for: id)
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
                "id": archived.id.uuidString, "offset": "0", "limit": "1",
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
        try await history.read(reference: .init(id: UUID()), offset: 0, limit: 1)
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
    let id = UUID()
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
    let input = AgentInput(sessionID: UUID(), payload: .event("fixture"))
    let envelope = OutputEnvelope(source: .assistant, input: input, output: .toolCall(call))
    let response = try await ToolExecutor(registry: registry).execute(call, envelope: envelope)
    #expect(response?.callID == id && response?.isError == false)
}

@Test(.actionCatalog) func historyShortReferenceReadsTheListedConversationAfterArchiveAndReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConversationHistoryStore(files: try ConversationFileStore(directory: directory))
    try await historyTurn(store, user: "recorded input", response: "actual answer")
    let history = HistoryQueryService(store: store)
    let listed = try #require(try historyObject(await history.list(offset: 0, limit: 1))["items"] as? [[String: Any]])
    let ref = try #require(listed[0]["ref"] as? String)
    let fullID = try #require(listed[0]["id"] as? String)
    #expect(ref.count == 8 && fullID.hasPrefix(ref))
    _ = try await store.startNew()
    let reopened = ConversationHistoryStore(files: try ConversationFileStore(directory: directory))
    let reader = HistoryQueryService(store: reopened)
    let shortResult = try await HistoryActions.read(
        invocation: historyRequest("History.Conversation.read", ["id": ref.lowercased(), "offset": "0", "limit": "2"]),
        using: reader)
    let fullResult = try await HistoryActions.read(
        invocation: historyRequest("History.Conversation.read", ["id": fullID, "offset": "0", "limit": "2"]),
        using: reader)
    #expect(shortResult == fullResult)
    let items = try #require(try historyObject(shortResult)["items"] as? [[String: Any]])
    #expect((items[0]["response"] as? [String: Any])?["value"] as? String == "actual answer")
    let wrongSuffix = fullID.hasSuffix("0000") ? "FFFF" : "0000"
    let typo = String(fullID.dropLast(4)) + wrongSuffix
    await #expect(throws: HistoryQueryError.missingConversation) {
        try await reader.read(reference: .init(typo), offset: 0, limit: 1)
    }
}

@Test(.actionCatalog) func historyShortReferenceCollisionsRequireExactFullUUIDs() async throws {
    func record(_ id: String, archived: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["id": id, "createdAt": 0, "turns": [], "taskCompressions": []]
        if archived { value["archivedAt"] = 1 }
        return value
    }
    let ids = ["FA47DFEA-A7FC-4F1C-9B10-B57B1EA0E5D6", "FA47DFEA-A7FC-4F1C-9B10-B57B1EA0E36D"]
    let data = try JSONSerialization.data(withJSONObject: [
        "version": 3, "revision": 0, "current": record(ids[0]), "past": [record(ids[1], archived: true)],
    ])
    let archive = try JSONDecoder().decode(ConversationArchive.self, from: data)
    let store = ConversationHistoryStore(
        contextLoad: { archive }, contextCommit: { _ in Issue.record("Read mutated history") })
    let reader = HistoryQueryService(store: store)
    let entries = try #require(try historyObject(await reader.list(offset: 0, limit: 2))["items"] as? [[String: Any]])
    #expect(entries.count == 2 && entries.allSatisfy { $0["ref"] == nil })
    await #expect(throws: HistoryQueryError.ambiguousConversationReference) {
        try await reader.read(reference: .init("fa47dfea"), offset: 0, limit: 1)
    }
    for id in ids {
        #expect(try historyObject(await reader.read(reference: .init(id), offset: 0, limit: 1))["total"] as? Int == 0)
    }
    await #expect(throws: HistoryQueryError.missingConversation) {
        try await reader.read(reference: .init("00000000"), offset: 0, limit: 1)
    }
}

@Test(.actionCatalog) func historyReferenceValidationRejectsInvalidShortValuesBeforeQuerying() async throws {
    let probe = HistoryQueryProbe()
    for id in ["FA47DFE", "FA47DFEAZ", "FA47DFEG", "current", " FA47DFEA", "ＦＡ４７ＤＦＥＡ"] {
        await #expect(throws: ActionArguments.ValidationError.self) {
            try await HistoryActions.read(
                invocation: historyRequest("History.Conversation.read", ["id": id, "offset": "0", "limit": "1"]),
                using: probe)
        }
    }
    #expect(await probe.calls == 0)
}
