import Actions
import Agents
import Foundation
import ModelKit
import StorageChat
import StorageCore
import StorageDatabase
import StorageFiles
import StorageMedia
import StorageSQLite
import StorageTasks
import Testing
import UI

#if canImport(SQLite3)
    import SQLite3

    private func schemaRows(_ url: URL, _ sql: String) throws -> [[String]] {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let connection else {
            throw RecordStorageError.invalidRecord
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RecordStorageError.invalidRecord
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append(
                (0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw RecordStorageError.invalidRecord }
        return rows
    }

    @Test func storageSchemaHasTenTablesAndRoundRequestSeparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("records.sqlite")
        let database = try SQLiteRepositories(url: url)
        let records = try ConversationRecordStore(repository: database.chat, tasks: database.tasks)
        let history = ConversationHistoryStore(records: records)
        let snapshot = try await history.readCurrent()
        _ = try await history.begin(
            id: "input", user: "Draw", request: [.init(role: .system, content: "dynamic system")],
            expecting: snapshot.token, model: "model")
        let first = UUID().uuidString
        let second = UUID().uuidString
        try await history.beginModelRequest(
            .init(id: first, input: "Draw", requestJSON: "[{\"role\":\"system\",\"content\":\"dynamic system\"}]"),
            for: "input")
        try await history.append("Step one", to: "input")
        try await history.finishModelRequest("input", reason: "stop")
        try await history.beginModelRequest(.init(id: second, input: "Observation", requestJSON: "[]"), for: "input")
        let recording = try AgentModelRequestRecording(
            ChatRequest(
                messages: [.init(role: .system, content: "dynamic state"), .init(role: .user, content: "Observation")],
                temperature: 0.2))
        recording.record(.text("Step two"))
        let exchange = try recording.snapshot()
        try await history.recordModelExchange(
            requestJSON: exchange.requestJSON, response: exchange.responseJSON, for: "input")
        try await history.append("Step two", to: "input")
        try await history.finishModelRequest("input", reason: "stop")
        try await history.finish("input", state: .completed)
        let tables = try schemaRows(
            url, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).compactMap(\.first)
        #expect(
            tables == [
                "agent_delegations", "assistant_conversations", "assistant_tasks", "devices", "media_files",
                "message_media", "messages", "model_request_log", "workspace_files", "writer_tasks",
            ])
        #expect(try schemaRows(url, "SELECT COUNT(*) FROM messages") == [["1"]])
        #expect(try schemaRows(url, "SELECT COUNT(*) FROM model_request_log") == [["2"]])
        #expect(
            try schemaRows(url, "SELECT detail_json FROM messages").allSatisfy {
                !$0.joined().contains("dynamic system")
            })
        #expect(
            try schemaRows(url, "SELECT request_json FROM model_request_log WHERE request_id='\(second)'").first?.first?
                .contains("dynamic state") == true)
        let request = try #require(try database.chat.previews(dialog: snapshot.current.id).last?.id)
        let restored = try await records.message(request)
        #expect(restored.turns.first?.modelRequests?.first?.responseEventsJSON?.contains("Step two") == true)
        #expect(try schemaRows(url, "PRAGMA foreign_key_check").isEmpty)
        try await database.shutdown()
    }
#endif

@Test func workspaceRepairsInterruptedIndexAndRejectsMissingPublishedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("records.sqlite")
    let database = try await workspaceFixtureRepositories(url: url)
    let disk = try DiskFileStore(root: root.appendingPathComponent("files"))
    let workspace = ArtifactWorkspace(disk: disk, catalog: database.workspaces)
    let id = try #require(WorkspaceID(agent: "writer", taskID: "task_1"))
    let original = try await workspace.publish(
        id: id, expecting: nil, title: "Test", draft: ArtifactDraft(files: ["index.html": "before", "empty.css": ""]))
    try await database.workspaces.claim(id, expecting: original.revision, lease: UUID())
    try await disk.replace(Data("after".utf8), key: id.rawValue + "/index.html")
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    try reopened.recoverInFlight()
    let recovered = ArtifactWorkspace(disk: disk, catalog: reopened.workspaces)
    #expect(try await recovered.checkpoint(for: id)?.draft.files["index.html"] == "after")
    #expect(try await recovered.project(id).files["empty.css"] == "")
    let saved = try await recovered.publish(
        id: id, expecting: original.revision, title: "Saved",
        draft: ArtifactDraft(files: ["index.html": "after", "empty.css": ""]))
    try await disk.remove(id.rawValue + "/index.html")
    await #expect(throws: FileStorageError.invalidFile) { try await recovered.project(id) }
    #expect(saved.revision != original.revision)
    try await reopened.shutdown()
}

@Test func workspaceRequiresOwnedTaskAndActiveTaskDeletionIsRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteRepositories.temporary()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: database.workspaces)
    let id = try #require(WorkspaceID(agent: "writer", taskID: "task_1"))
    let draft = try ArtifactDraft(files: ["index.html": "test"])
    await #expect(throws: RecordStorageError.missingRecord) {
        try await workspace.publish(id: id, expecting: nil, title: "Unowned", draft: draft)
    }
    let task = try await database.tasks.seedDelegation(
        taskID: nil, goal: "Task", input: "Draw", sourceDialog: nil, agent: "writer")
    _ = try await workspace.publish(id: id, expecting: nil, title: "Owned", draft: draft)
    await #expect(throws: RecordStorageError.conflict) { try await workspace.delete(id) }
    try await database.tasks.endSeedDelegation(task.delegateID, status: "cancelled")
    try await workspace.delete(id)
    let next = try await database.tasks.seedDelegation(
        taskID: nil, goal: "Next", input: "Draw", sourceDialog: nil, agent: "writer")
    #expect(next.id == "task_2")
    try await database.shutdown()
}

@Test func rawRoundPaginationPreservesAllNestedRequestsAndOriginalInputs() async throws {
    let database = try SQLiteRepositories.temporary()
    let records = try ConversationRecordStore(repository: database.chat, tasks: database.tasks)
    let history = ConversationHistoryStore(records: records)
    let dialog = try await history.readCurrent().current.id
    for number in 0..<60 {
        let input = "round-\(number)"
        _ = try await history.begin(
            id: input, user: input, request: [], expecting: history.readCurrent().token, model: "fixture")
        for step in 1...2 {
            try await history.beginModelRequest(
                .init(id: UUID().uuidString, input: "step \(step)", requestJSON: "[]"), for: input)
            try await history.append("result \(number).\(step)", to: input)
            try await history.finishModelRequest(input, reason: "stop")
        }
        try await history.finish(input, state: .completed)
    }
    let restored = try await records.read(dialog)
    #expect(restored.turns.count == 60)
    #expect(restored.turns.allSatisfy { $0.modelRequests?.count == 2 })
    #expect(restored.turns.last?.modelRequests?.last?.response == "result 59.2")
    #expect(try database.chat.storageStatistics().messages == 60)
    #expect(try database.chat.storageStatistics().requests == 120)
    try await database.shutdown()
}

/// Generates only synthetic records for the separate native simulator UI acceptance script.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MH_STORAGE_UI_FIXTURE_ROOT"] != nil))
func storageSyntheticWriterUIFixture() async throws {
    let directory = try #require(ProcessInfo.processInfo.environment["MH_STORAGE_UI_FIXTURE_ROOT"])
    let root = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try SQLiteRepositories(url: root.appendingPathComponent("records.sqlite"))
    let task = try await database.tasks.seedDelegation(
        taskID: nil, goal: "绘制简单测试流程图", input: "Draw a simple chart", sourceDialog: nil, agent: "writer")
    let history = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: database.chat, tasks: database.tasks, agent: "writer"))
    let source = "<!doctype html><meta charset=utf-8><title>测试流程图</title><h1>测试流程图</h1><p>开始 → 检查 → 完成</p>"
    for phase in ["控制请求", "文件内容请求"] {
        let input = UUID().uuidString
        _ = try await history.begin(
            id: input, user: task.goal, request: [], expecting: history.readCurrent().token, model: "synthetic-fixture")
        var decision = ConversationDecisionMetadata(
            taskID: task.id, mode: phase, skills: [:], catalogJSON: "{}", execution: "background")
        decision.delegateID = task.delegateID
        var request = ConversationModelRequest(
            id: UUID().uuidString, input: task.goal, requestJSON: "[]", decisionMetadata: decision)
        request.producerMetadata = ["phase": phase, "path": "index.html", "attempt": "1"]
        try await history.beginModelRequest(request, for: input)
        let date = Date()
        try await history.recordModelTiming(
            startedAt: date, firstTokenAt: date.addingTimeInterval(0.1), latency: 0.1, for: input)
        try await history.append(phase == "文件内容请求" ? source : "创建流程图", to: input)
        try await history.finishModelRequest(input, reason: "stop")
        try await history.finish(input, state: .completed)
    }
    let workspace = ArtifactWorkspace(
        disk: try DiskFileStore(root: root.appendingPathComponent("workspaces")), catalog: database.workspaces)
    _ = try await workspace.publish(
        id: #require(WorkspaceID(rawValue: task.workspaceID)), expecting: nil, title: "测试流程图",
        draft: ArtifactDraft(files: ["index.html": source, "empty.css": ""]))
    try await database.tasks.endSeedDelegation(task.delegateID, status: "completed")
    for retirement in [false, true] {
        try await database.tasks.finishTaskNotification(
            task.delegateID, agent: "writer", retirement: retirement, completed: true, failure: nil)
    }
    try await database.shutdown()
}

@Test func deletingWriterWorkspacePreservesAssistantReportRequestEvidence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try await workspaceFixtureRepositories()
    let task = try await database.tasks.delegatedTask("task_1", agent: "writer")
    let records = try ConversationRecordStore(repository: database.chat, tasks: database.tasks)
    let history = ConversationHistoryStore(records: records)
    let snapshot = try await history.readCurrent()
    _ = try await history.begin(
        id: "writer-report", user: "Writer completed", request: [], expecting: snapshot.token, model: "fixture")
    var metadata = ConversationDecisionMetadata(taskID: task.id, mode: "writer.event", skills: [:], catalogJSON: "{}")
    metadata.delegateID = task.delegateID
    try await history.beginModelRequest(
        .init(id: UUID().uuidString, input: "Writer completed", requestJSON: "[]", decisionMetadata: metadata),
        for: "writer-report")
    try await history.append("Your work is ready", to: "writer-report")
    try await history.finishModelRequest("writer-report", reason: "stop")
    try await history.finish("writer-report", state: .completed)
    let selected = try #require(try database.chat.previews(dialog: snapshot.current.id).first?.id)
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: database.workspaces)
    let id = try #require(WorkspaceID(rawValue: task.workspaceID))
    _ = try await workspace.publish(
        id: id, expecting: nil, title: "Test", draft: ArtifactDraft(files: ["index.html": "<h1>Done</h1>"]))
    try await workspace.delete(id)
    #expect(try await records.message(selected).turns.first?.modelRequests?.first?.response == "Your work is ready")
    #expect(try database.chat.storageStatistics().requests == 1)
    try await database.shutdown()
}

@Test func agentRecordingRetainsFullRequestAndExposedNativeEvents() throws {
    let arguments = "{\"source\":\"" + String(repeating: "长内容", count: 40000) + "\"}"
    let request = try ChatRequest(
        messages: [.init(role: .system, content: "Dynamic state"), .init(role: .user, content: "Draw")],
        temperature: 0.3)
    let recording = try AgentModelRequestRecording(request)
    recording.record(.text("Before tool"))
    recording.record(.toolCall(.init(id: "native-1", name: "workspace", argumentsJSON: arguments)))
    recording.record(.usage(try .init(input: 10, generated: 20, total: 30)))
    recording.record(.finished(.toolCalls))
    let snapshot = try recording.snapshot()
    let parameters = try #require(JSONSerialization.jsonObject(with: Data(snapshot.requestJSON.utf8)) as? [String: Any])
    #expect(parameters["temperature"] as? Double == 0.3)
    #expect(parameters["maximumOutputTokens"] == nil)
    #expect(snapshot.requestJSON.contains("Dynamic state"))
    let events = try #require(JSONSerialization.jsonObject(with: Data(snapshot.responseJSON.utf8)) as? [[String: Any]])
    #expect(events.count == 4)
    #expect((events[1]["call"] as? [String: Any])?["argumentsJSON"] as? String == arguments)
}

@Test func newTaskRequestInvalidatesAnEarlierSummaryAtAdmission() async throws {
    let database = try SQLiteRepositories.temporary()
    let dialog = try await database.chat.current(agent: "assistant")
    let task = try await database.tasks.createTask(dialog: dialog.id, agent: "assistant", goal: "Task")
    let first = UUID().uuidString
    let input = UUID().uuidString
    let response = MessageRecord(
        clientID: first, inputID: input, role: "assistant", kind: "response", order: 1, date: Date(), body: "First",
        state: "completed", taskID: task, detail: Data("{}".utf8))
    let compression = ConversationTaskCompression(
        taskID: task, goal: "Task", status: .completed, reportedSummary: "Done", failure: nil, completedAt: Date(),
        sources: [.init(inputID: input, requestID: first)])
    try await database.chat.save(
        dialog: dialog.id, revision: 1, recovery: nil, messages: [response],
        summaries: [
            .init(
                id: task, goal: "Task", status: "completed", summary: "Done", failure: nil, finishedAt: Date(),
                sources: [first], detail: JSONEncoder().encode(compression))
        ])
    #expect(try await database.chat.compressionData(dialog: dialog.id).count == 1)
    _ = try await database.chat.beginMessage(
        dialog: dialog.id,
        identity: .init(
            clientID: UUID().uuidString, inputID: input, role: "assistant", kind: "response", order: 2, date: Date(),
            taskID: task))
    #expect(try await database.chat.compressionData(dialog: dialog.id).isEmpty)
    #expect(try await database.chat.previews(dialog: dialog.id).count == 2)
    try await database.shutdown()
}

@Test func foregroundTaskAssignmentMovesReservedRequestWithoutLosingEarlierReACT() async throws {
    let database = try SQLiteRepositories.temporary()
    let records = try ConversationRecordStore(repository: database.chat, tasks: database.tasks)
    let history = ConversationHistoryStore(records: records)
    let initial = try await history.readCurrent()
    let input = UUID().uuidString
    _ = try await history.begin(id: input, user: "帮我拍张照", request: [], expecting: initial.token, model: "fixture")
    let load = UUID().uuidString
    try await history.beginModelRequest(.init(id: load, input: "帮我拍张照", requestJSON: "[]"), for: input)
    try await history.append("<loadSkills skills='[\"photography\"]'/>", to: input)
    try await history.finishModelRequest(input, reason: "stop")
    let starting = UUID().uuidString
    try await history.beginModelRequest(.init(id: starting, input: "Skill loaded", requestJSON: "[]"), for: input)
    let address = try #require(try await history.snapshot().current.turns.first?.modelRequests?.last?.messageID)
    let task = try await database.tasks.createTask(dialog: initial.current.id, agent: "assistant", goal: "拍照并等待处理")
    var captured = try await history.snapshot()
    try captured.assignHistoryTask(task, inputID: input, requestID: starting)
    captured.current.turns[0].modelRequests?[1].state = .completed
    captured.current.turns[0].modelRequests?[1].response = "<startTask goal=\"拍照并等待处理\"/>"
    try await records.saveCurrent(.init(conversation: captured.current, revision: captured.revision))
    // The same checkpoint can be retried without moving or duplicating the reserved request again.
    try await records.saveCurrent(.init(conversation: captured.current, revision: captured.revision))
    let sources = try await database.chat.taskSources(task)
    #expect(sources.map(\.requestID) == [starting])
    let details = try await records.message(address)
    #expect(details.turns.first?.modelRequests?.first?.historyTaskID == task)
    #expect(try await records.requestCount(initial.current.id) == 2)
    #expect(try await database.chat.dialog(initial.current.id).count == 1)
    #expect(try await records.read(initial.current.id).turns.first?.modelRequests?.map(\.id) == [load, starting])
    try await database.shutdown()
}

@Test func taskAssignmentPreservesSingleRequestAddressAndRejectsForeignRebinding() async throws {
    let database = try SQLiteRepositories.temporary()
    let dialog = try await database.chat.current(agent: "assistant")
    let input = UUID().uuidString
    let request = UUID().uuidString
    let identity = MessageIdentity(
        clientID: request, inputID: input, role: "assistant", kind: "response", order: 1, date: Date())
    let reserved = try await database.chat.beginMessage(dialog: dialog.id, identity: identity)
    let task = try await database.tasks.createTask(dialog: dialog.id, agent: "assistant", goal: "Photo")
    let assigned = MessageRecord(
        clientID: request, inputID: input, role: "assistant", kind: "response", order: 1, date: Date(),
        body: "<startTask/>", state: "completed", taskID: task, detail: Data("{}".utf8))
    let saved = try await database.chat.save(
        dialog: dialog.id, revision: 1, recovery: nil, messages: [assigned], summaries: [])
    #expect(saved.first?.id == reserved)
    #expect(try database.chat.storageStatistics().messages == 1)
    let other = try await database.tasks.createTask(dialog: dialog.id, agent: "assistant", goal: "Other")
    let rebind = MessageRecord(
        clientID: request, inputID: input, role: "assistant", kind: "response", order: 1, date: Date(), body: "bad",
        state: "completed", taskID: other, detail: Data("{}".utf8))
    await #expect(throws: RecordStorageError.conflict) {
        try await database.chat.save(dialog: dialog.id, revision: 2, recovery: nil, messages: [rebind], summaries: [])
    }
    #expect(try await database.chat.messageEvidence(reserved).last?.body == "<startTask/>")
    let foreign = try await database.chat.current(agent: "other")
    await #expect(throws: RecordStorageError.conflict) {
        try await database.chat.save(
            dialog: foreign.id, revision: 1, recovery: nil, messages: [assigned], summaries: [])
    }
    #expect(try await database.chat.messages(dialog: foreign.id).isEmpty)
    try await database.shutdown()
}

@Test func pendingDelegationStatusIsANormalReadAndDatabaseFailuresStillPropagate() async throws {
    let database = try SQLiteRepositories.temporary()
    let id = UUID().uuidString
    #expect(try await database.tasks.delegationStatus(id, agent: "writer") == nil)
    try await database.tasks.createDelegation(
        id: id, requester: "assistant", executor: "writer", goal: "Draw", input: "Draw", sourceDialog: nil)
    #expect(try await database.tasks.delegationStatus(id, agent: "writer") == "requested")
    let task = try await database.tasks.beginDelegation(
        delegateID: id, taskID: nil, goal: "Draw", input: "Draw", sourceDialog: nil, agent: "writer")
    #expect(try await database.tasks.delegationStatus(id, agent: "writer") == "running")
    #expect(try await database.tasks.delegation(id, agent: "writer").taskID == task.id)
    try await database.shutdown()
    await #expect(throws: RecordStorageError.closed) { try await database.tasks.delegationStatus(id, agent: "writer") }
}

@Test @MainActor func sqlitePhotoRequestDetailReadsOriginalImageThroughHistoryWorkflow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteRepositories.temporary()
    let media = MediaStore(repository: database.media, files: try DiskFileStore(root: root))
    let input = UUID().uuidString
    let bytes = Data([1, 2, 3, 4])  // Byte-reader fixture; native decoding is separate.
    let photo = try await media.save(
        bytes, owner: .init(namespace: "photos", source: "assistant", session: "photo-session", input: input))
    let records = try ConversationRecordStore(repository: database.chat, tasks: database.tasks)
    let store = ConversationHistoryStore(records: records)
    let initial = try await store.readCurrent()
    _ = try await store.begin(id: input, user: "Photo", request: [], expecting: initial.token, model: "fixture")
    let requestJSON = String(
        decoding: try JSONSerialization.data(withJSONObject: [
            [
                "role": "user", "content": "Photo result",
                "imageReferences": [["id": photo, "mimeType": "image/jpeg", "byteCount": bytes.count]],
            ]
        ]), as: UTF8.self)
    try await store.beginModelRequest(
        .init(id: UUID().uuidString, input: "Photo result", requestJSON: requestJSON), for: input)
    try await store.append("Save or ignore?", to: input)
    try await store.finishModelRequest(input, reason: "stop")
    try await store.finish(input, state: .completed)
    let state = ConversationHistoryState()
    state.present(try await HistoryPresentationAdapter.listPresentation(store), status: nil)
    let workflow = ConversationHistoryWorkflow.records(
        store: store, state: state, mutate: { _, _ in },
        readPhoto: { id, owner in
            try await media.readForInput(id, source: "assistant", input: owner)
        })
    let conversation = try await workflow.loadConversation(initial.current.id)
    let row = try #require(ConversationHistoryPresentation.turns(conversation).first)
    let detail = try await workflow.loadMessage(row)
    #expect(detail.attachedImages.map(\.id) == [photo])
    #expect(try await workflow.imageData(photo, for: detail.id) == bytes)
    await workflow.shutdown()
    try await database.shutdown()
}
