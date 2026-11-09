import Actions
import Agents
import Foundation
import ModelKit
import StorageCache
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

    @Test func storageSchemaSeparatesBusinessRequestsFromOptionalLogs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("records.sqlite")
        let database = try SQLiteRepositories(url: url)
        let records = try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs)
        let history = AssistantHistoryStore(records: records)
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
            requestJSON: exchange.requestJSON, response: exchange.responseJSON, for: "input", initial: true)
        try await history.append("Step two", to: "input")
        try await history.finishModelRequest("input", reason: "stop")
        try await history.finish("input", state: .completed)
        let tables = try schemaRows(
            url, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).compactMap(\.first)
        #expect(
            tables == [
                "agent_messages", "assistant_conversations", "assistant_messages", "assistant_tasks", "devices",
                "media_files",
                "model_request_log", "workspace_files", "writer_messages", "writer_workspaces",
            ])
        #expect(try schemaRows(url, "SELECT COUNT(*) FROM assistant_messages") == [["2"]])
        #expect(try schemaRows(url, "SELECT COUNT(*) FROM assistant_messages") == [["2"]])
        #expect(
            try schemaRows(url, "SELECT user_input_json || assistant_response_json FROM assistant_messages").allSatisfy
            {
                !$0.joined().contains("dynamic system")
            })
        #expect(
            try schemaRows(
                url,
                "SELECT CAST(request_body AS TEXT) FROM model_request_log WHERE invocation_id='\(second)'"
            ).first?.first?
            .contains("dynamic state") == true)
        let request = try #require(try database.assistantMessages.previews(dialog: snapshot.current.id).last?.id)
        let restored = try await records.message(request)
        #expect(restored.turns.first?.modelRequests?.first?.responseEventsJSON?.contains("Step two") == true)
        #expect(try schemaRows(url, "PRAGMA foreign_key_check").isEmpty)
        try await database.shutdown()
    }
    private func beginLoggedFixture(_ history: AssistantHistoryStore, input: String) async throws -> String {
        _ = try await history.begin(
            id: input, user: "inspect image", request: [], expecting: history.readCurrent().token, model: "fixture")
        let id = UUID().uuidString
        try await history.beginModelRequest(.init(id: id, input: "inspect image", requestJSON: "[]"), for: input)
        return id
    }

    private func beginLoggedFixture(_ history: WriterHistoryStore, input: String) async throws -> String {
        _ = try await history.begin(
            id: input, user: "inspect image", request: [], expecting: history.readCurrent().token, model: "fixture")
        let id = UUID().uuidString
        try await history.beginModelRequest(.init(id: id, input: "inspect image", requestJSON: "[]"), for: input)
        return id
    }

    @Test func completeRequestLogsSurviveReopenAndDeleteWithoutBusinessLossOrResurrection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("records.sqlite")
        let database = try SQLiteRepositories(url: url)
        let records = try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs)
        let history = AssistantHistoryStore(records: records)
        let uuid = try await beginLoggedFixture(history, input: "original")
        let bytes = Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9])
        let audit = try AgentModelRequestRecording(
            ChatRequest(messages: [
                .init(
                    role: .user, content: "inspect image",
                    images: [.init(id: "preview_1", mimeType: "image/jpeg", data: bytes)])
            ]))
        let initial = try audit.snapshot(initial: true)
        try await history.recordModelExchange(
            requestJSON: initial.requestJSON, response: initial.responseJSON, for: "original", initial: true)
        try await history.append("observed reply", to: "original")
        try await history.recordModelTiming(startedAt: Date(), firstTokenAt: nil, latency: nil, for: "original")
        let dialog = try await history.readCurrent().current.id
        let requestID = try #require(try database.assistantMessages.previews(dialog: dialog).last?.id)
        #expect(try await records.window(dialog).turns.first?.modelRequests?.first?.requestParametersJSON == nil)
        #expect(
            try schemaRows(url, "SELECT assistant_response_json FROM assistant_messages").allSatisfy {
                !$0.joined().contains(bytes.base64EncodedString())
            })
        try await database.shutdown()

        let reopened = try SQLiteRepositories(url: url)
        let restored = try AssistantRecordStore(
            repository: reopened.assistantMessages, tasks: reopened.assistantTasks,
            conversations: reopened.assistantConversations, logs: reopened.logs)
        let detail = try await restored.message(requestID)
        let view = try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(detail))
        let turn = try #require(ConversationHistoryPresentation.turns(view).first)
        #expect(HistoryRecordedImages.data("preview_1", json: turn.requestParametersJSON) == bytes)
        #expect(turn.attachedImages.first?.byteCount == bytes.count)
        let exported = try JSONDecoder().decode(HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(turn))
        #expect(HistoryRecordedImages.data("preview_1", json: exported.requestParametersJSON) == bytes)
        let before = try schemaRows(
            url, "SELECT id,input_key,assistant_response_json,state,tool_calls_json FROM assistant_messages")
        let messages = try schemaRows(
            url, "SELECT id,input_key,user_input_json,assistant_response_json FROM assistant_messages")
        try await restored.clearRequestLogs(requestID: requestID)
        try await restored.clearRequestLogs(requestID: requestID)
        audit.record(.text("late model completion"))
        let late = try audit.snapshot()
        try await reopened.logs.writeRequestPayload(
            uuid, agent: "assistant", json: late.requestJSON, response: late.responseJSON, initial: false)
        let cleared = try await restored.message(requestID)
        let clearedView = try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(cleared))
        let clearedTurn = try #require(ConversationHistoryPresentation.turns(clearedView).first)
        #expect(clearedTurn.logsCleared == true && clearedTurn.attachedImages.isEmpty)
        #expect(clearedTurn.raw == turn.raw && clearedTurn.modelRequestStartedAt == nil)
        #expect(try schemaRows(url, "SELECT COUNT(*) FROM model_request_log") == [["0"]])
        #expect(
            try schemaRows(
                url, "SELECT id,input_key,assistant_response_json,state,tool_calls_json FROM assistant_messages")
                == before)
        #expect(
            try schemaRows(url, "SELECT id,input_key,user_input_json,assistant_response_json FROM assistant_messages")
                == messages)
        #expect(try schemaRows(url, "PRAGMA foreign_key_check").isEmpty)
        try await reopened.shutdown()
    }

    @Test func completeRequestLogsClearWholeLibraryAcrossAgentsAndFenceBusinessCheckpoints() async throws {
        let database = try SQLiteRepositories.temporary()
        let assistantRecords = try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs)
        let assistant = AssistantHistoryStore(records: assistantRecords)
        _ = try await beginLoggedFixture(assistant, input: "assistant-input")
        _ = try await database.seedDelegation(
            workspaceID: nil, goal: "Writer", input: "write", sourceDialog: nil, agent: "writer")
        let writerRecords = try WriterRecordStore(repository: database.writerMessages, logs: database.logs)
        let writer = WriterHistoryStore(records: writerRecords)
        _ = try await beginLoggedFixture(writer, input: "writer-input")

        try await assistant.recordModelExchange(
            requestJSON: "{\"messages\":[]}", response: "[]", for: "assistant-input", initial: true)
        try await writer.recordModelExchange(
            requestJSON: "{\"messages\":[]}", response: "[]", for: "writer-input", initial: true)
        let assistantDialog = try await assistant.readCurrent().current.id
        let writerDialog = try await writer.readCurrent().current.id
        let assistantID = try #require(try database.assistantMessages.previews(dialog: assistantDialog).first?.id)
        let writerID = try #require(try database.writerMessages.previews(ownerID: writerDialog).last?.id)
        await #expect(throws: RecordStorageError.missingRecord) {
            try await assistantRecords.clearRequestLogs(requestID: writerID)
        }
        try await assistantRecords.clearRequestLogs(requestID: assistantID)
        #expect(try await database.logs.requestPayload(writerID, agent: "writer") != nil)
        var title = AssistantModelRequest(id: UUID().uuidString, input: "title", requestJSON: "{\"messages\":[]}")
        try database.assistantConversations.saveAuxiliaryRequest(dialog: assistantDialog, request: title)
        try await writerRecords.clearRequestLogs(requestID: nil)
        title.response = "A conversation title"
        title.state = .completed
        try database.assistantConversations.saveAuxiliaryRequest(dialog: assistantDialog, request: title)
        #expect(try database.storageStatistics().requestLogBytes == 0)

        try await assistant.recordModelExchange(
            requestJSON: "{\"messages\":[]}", response: "[{\"text\":\"done\"}]", for: "assistant-input")
        try await assistant.append("done", to: "assistant-input")
        try await assistant.finishModelRequest("assistant-input", reason: "stop")
        try await assistant.finish("assistant-input", state: .completed)
        try await writer.recordModelExchange(
            requestJSON: "{\"messages\":[]}", response: "[{\"text\":\"done\"}]", for: "writer-input")
        try await writer.append("done", to: "writer-input")
        try await writer.finishModelRequest("writer-input", reason: "stop")
        try await writer.finish("writer-input", state: .completed)
        #expect(try await database.logs.requestPayload(assistantID, agent: "assistant") == nil)
        #expect(try await database.logs.requestPayload(writerID, agent: "writer") == nil)
        #expect(try await assistantRecords.message(assistantID).turns.first?.modelRequests?.first?.response == "done")
        #expect(try await writerRecords.message(writerID).turns.first?.modelRequests?.first?.response == "done")
        #expect(try database.storageStatistics().messages == 3)
        #expect(try database.storageStatistics().requests == 2)
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
    let id = try #require(WorkspaceID(rawValue: "workspace_1"))
    let original = try await workspace.publish(
        id: id, expecting: nil, title: "Test", draft: ArtifactDraft(files: ["index.html": "before", "empty.css": ""]))
    try await database.workspaces.claim(id, expecting: original.revision, lease: UUID())
    try await disk.replace(Data("after".utf8), key: id.storagePath + "/index.html")
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    try reopened.recoverInFlight()
    let recovered = ArtifactWorkspace(disk: disk, catalog: reopened.workspaces)
    #expect(try await recovered.checkpoint(for: id)?.draft.files["index.html"] == "after")
    #expect(try await recovered.project(id).files["empty.css"] == "")
    let saved = try await recovered.publish(
        id: id, expecting: original.revision, title: "Saved",
        draft: ArtifactDraft(files: ["index.html": "after", "empty.css": ""]))
    try await disk.remove(id.storagePath + "/index.html")
    await #expect(throws: FileStorageError.invalidFile) { try await recovered.project(id) }
    #expect(saved.revision != original.revision)
    try await reopened.shutdown()
}

@Test func workspaceRequiresOwnedTaskAndActiveTaskDeletionIsRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteRepositories.temporary()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: database.workspaces)
    let id = try #require(WorkspaceID(rawValue: "workspace_1"))
    let draft = try ArtifactDraft(files: ["index.html": "test"])
    await #expect(throws: RecordStorageError.missingRecord) {
        try await workspace.publish(id: id, expecting: nil, title: "Unowned", draft: draft)
    }
    let task = try await database.seedDelegation(
        workspaceID: nil, goal: "Task", input: "Draw", sourceDialog: nil, agent: "writer")
    _ = try await workspace.publish(id: id, expecting: nil, title: "Owned", draft: draft)
    await #expect(throws: RecordStorageError.conflict) { try await workspace.delete(id) }
    try await database.endSeedDelegation(task.delegateID, status: "cancelled")
    try await workspace.delete(id)
    let next = try await database.seedDelegation(
        workspaceID: nil, goal: "Next", input: "Draw", sourceDialog: nil, agent: "writer")
    #expect(next.id == "workspace_2")
    try await database.shutdown()
}

@Test func rawRoundPaginationPreservesAllNestedRequestsAndOriginalInputs() async throws {
    let database = try SQLiteRepositories.temporary()
    let records = try AssistantRecordStore(
        repository: database.assistantMessages, tasks: database.assistantTasks,
        conversations: database.assistantConversations, logs: database.logs)
    let history = AssistantHistoryStore(records: records)
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
    #expect(try database.storageStatistics().messages == 120)
    #expect(try database.storageStatistics().requests == 120)
    try await database.shutdown()
}

/// Generates only synthetic records for the separate native simulator UI acceptance script.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MH_STORAGE_UI_FIXTURE_ROOT"] != nil))
func storageSyntheticWriterUIFixture() async throws {
    let directory = try #require(ProcessInfo.processInfo.environment["MH_STORAGE_UI_FIXTURE_ROOT"])
    let root = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try SQLiteRepositories(url: root.appendingPathComponent("records.sqlite"))
    let task = try await database.seedDelegation(
        workspaceID: nil, goal: "绘制简单测试流程图", input: "Draw a simple chart", sourceDialog: nil, agent: "writer")
    let history = WriterHistoryStore(
        records: try WriterRecordStore(repository: database.writerMessages, logs: database.logs))
    let source = "<!doctype html><meta charset=utf-8><title>测试流程图</title><h1>测试流程图</h1><p>开始 → 检查 → 完成</p>"
    for phase in ["控制请求", "文件内容请求"] {
        let input = UUID().uuidString
        _ = try await history.begin(
            id: input, user: task.title, request: [], expecting: history.readCurrent().token, model: "synthetic-fixture"
        )
        var decision = WriterDecisionMetadata(
            workspaceID: task.id, mode: phase, skills: [:], catalogJSON: "{}", execution: "background")
        decision.delegateID = task.delegateID
        var request = WriterModelRequest(
            id: UUID().uuidString, input: task.title, requestJSON: "[]", decisionMetadata: decision)
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
    try await database.endSeedDelegation(task.delegateID, status: "completed")
    for retirement in [false, true] {
        try await database.writerExecutions.finishDelegationNotification(
            task.delegateID, agent: "writer", retirement: retirement, completed: true, failure: nil)
    }
    try await database.shutdown()
}

@Test func deletingWriterWorkspacePreservesAssistantReportRequestEvidence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try await workspaceFixtureRepositories()
    let task = try await database.writerExecutions.workspace("workspace_1", agent: "writer")
    let records = try AssistantRecordStore(
        repository: database.assistantMessages, tasks: database.assistantTasks,
        conversations: database.assistantConversations, logs: database.logs)
    let history = AssistantHistoryStore(records: records)
    let snapshot = try await history.readCurrent()
    _ = try await history.begin(
        id: "writer-report", user: "Writer completed", request: [], expecting: snapshot.token, model: "fixture")
    var metadata = AssistantDecisionMetadata(taskID: task.id, mode: "writer.event", skills: [:], catalogJSON: "{}")
    metadata.delegateID = try await database.writerExecutions.requests(task.id, agent: "writer").first?.delegateID
    try await history.beginModelRequest(
        .init(id: UUID().uuidString, input: "Writer completed", requestJSON: "[]", decisionMetadata: metadata),
        for: "writer-report")
    try await history.append("Your work is ready", to: "writer-report")
    try await history.finishModelRequest("writer-report", reason: "stop")
    try await history.finish("writer-report", state: .completed)
    let selected = try #require(try database.assistantMessages.previews(dialog: snapshot.current.id).first?.id)
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: database.workspaces)
    let id = try #require(WorkspaceID(rawValue: task.workspaceID))
    _ = try await workspace.publish(
        id: id, expecting: nil, title: "Test", draft: ArtifactDraft(files: ["index.html": "<h1>Done</h1>"]))
    try await workspace.delete(id)
    #expect(try await records.message(selected).turns.first?.modelRequests?.first?.response == "Your work is ready")
    #expect(try database.storageStatistics().requests == 1)
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
    let dialog = try await database.assistantConversations.current()
    let task = try await database.assistantTasks.createTask(dialog: dialog.id, agent: "assistant", goal: "Task")
    let first = UUID().uuidString
    let input = UUID().uuidString
    let response = AssistantMessageRecord(
        clientID: first, inputID: input, role: "assistant", kind: "response", order: 1, date: Date(), body: "First",
        state: "completed", taskID: task, detail: Data("{}".utf8))
    let compression = AssistantTaskCompression(
        taskID: task, goal: "Task", status: .completed, reportedSummary: "Done", failure: nil, completedAt: Date(),
        sources: [.init(inputID: input, requestID: first)])
    try await database.assistantMessages.save(
        dialog: dialog.id, revision: 1, messages: [response],
        summaries: [
            .init(
                id: task, goal: "Task", status: "completed", summary: "Done", failure: nil, finishedAt: Date(),
                sources: [first], detail: JSONEncoder().encode(compression))
        ])
    #expect(try await database.assistantTasks.compressionData(dialog: dialog.id).count == 1)
    _ = try await database.assistantMessages.beginMessage(
        dialog: dialog.id,
        identity: .init(
            clientID: UUID().uuidString, inputID: input, role: "assistant", kind: "response", order: 2, date: Date(),
            taskID: task))
    #expect(try await database.assistantTasks.compressionData(dialog: dialog.id).isEmpty)
    #expect(try await database.assistantMessages.previews(dialog: dialog.id).count == 2)
    try await database.shutdown()
}

@Test func foregroundTaskAssignmentMovesReservedRequestWithoutLosingEarlierReACT() async throws {
    let database = try SQLiteRepositories.temporary()
    let records = try AssistantRecordStore(
        repository: database.assistantMessages, tasks: database.assistantTasks,
        conversations: database.assistantConversations, logs: database.logs)
    let history = AssistantHistoryStore(records: records)
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
    let task = try await database.assistantTasks.createTask(
        dialog: initial.current.id, agent: "assistant", goal: "拍照并等待处理")
    var captured = try await history.snapshot()
    try captured.assignHistoryTask(task, inputID: input, requestID: starting)
    captured.current.turns[0].modelRequests?[1].state = .completed
    captured.current.turns[0].modelRequests?[1].response = "<task.start description=\"拍照并等待处理\"/>"
    try await records.saveCurrent(.init(conversation: captured.current, revision: captured.revision))
    // The same checkpoint can be retried without moving or duplicating the reserved request again.
    try await records.saveCurrent(.init(conversation: captured.current, revision: captured.revision))
    let sources = try await database.assistantTasks.taskSources(task)
    #expect(sources.map(\.requestID) == [starting])
    let details = try await records.message(address)
    #expect(details.turns.first?.modelRequests?.first?.historyTaskID == task)
    #expect(try await records.requestCount(initial.current.id) == 2)
    #expect(try await database.assistantConversations.dialog(initial.current.id).count == 1)
    #expect(try await records.read(initial.current.id).turns.first?.modelRequests?.map(\.id) == [load, starting])
    try await database.shutdown()
}

@Test func taskAssignmentPreservesSingleRequestAddressAndRejectsForeignRebinding() async throws {
    let database = try SQLiteRepositories.temporary()
    let dialog = try await database.assistantConversations.current()
    let input = UUID().uuidString
    let request = UUID().uuidString
    let identity = AssistantMessageIdentity(
        clientID: request, inputID: input, role: "assistant", kind: "response", order: 1, date: Date())
    let reserved = try await database.assistantMessages.beginMessage(dialog: dialog.id, identity: identity)
    let task = try await database.assistantTasks.createTask(dialog: dialog.id, agent: "assistant", goal: "Photo")
    let assigned = AssistantMessageRecord(
        clientID: request, inputID: input, role: "assistant", kind: "response", order: 1, date: Date(),
        body: "<task.start/>", state: "completed", taskID: task, detail: Data("{}".utf8))
    let saved = try await database.assistantMessages.save(
        dialog: dialog.id, revision: 1, messages: [assigned], summaries: [])
    #expect(saved.first?.id == reserved)
    #expect(try database.storageStatistics().messages == 1)
    try await database.assistantTasks.endTask(task, status: "completed")
    let other = try await database.assistantTasks.createTask(dialog: dialog.id, agent: "assistant", goal: "Other")
    let rebind = AssistantMessageRecord(
        clientID: request, inputID: input, role: "assistant", kind: "response", order: 1, date: Date(), body: "bad",
        state: "completed", taskID: other, detail: Data("{}".utf8))
    await #expect(throws: RecordStorageError.conflict) {
        try await database.assistantMessages.save(dialog: dialog.id, revision: 2, messages: [rebind], summaries: [])
    }
    #expect(try await database.assistantMessages.messageEvidence(reserved).last?.body == "<task.start/>")
    await #expect(throws: RecordStorageError.invalidID) {
        try await database.assistantConversations.dialog("workspace_1")
    }
    try await database.shutdown()
}

@Test func pendingDelegationStatusIsANormalReadAndDatabaseFailuresStillPropagate() async throws {
    let database = try SQLiteRepositories.temporary()
    let id = UUID().uuidString
    #expect(try await database.writerExecutions.requestStatus(id, agent: "writer") == nil)
    try await database.agentMessages.seedAgentRequest(
        id: id, requester: "assistant", executor: "writer", goal: "Draw", input: "Draw", sourceDialog: nil)
    #expect(try await database.writerExecutions.requestStatus(id, agent: "writer") == "requested")
    let task = try await database.writerExecutions.beginRequest(
        delegateID: id, workspaceID: nil, goal: "Draw", input: "Draw", sourceDialog: nil, agent: "writer")
    #expect(try await database.writerExecutions.requestStatus(id, agent: "writer") == "running")
    #expect(try await database.writerExecutions.request(id, agent: "writer").messageID == task.messageID)
    try await database.shutdown()
    await #expect(throws: RecordStorageError.closed) {
        try await database.writerExecutions.requestStatus(id, agent: "writer")
    }
}

@Test @MainActor func sqlitePhotoRequestDetailReadsLoggedImageThroughHistoryWorkflow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteRepositories.temporary()
    let media = MediaStore(repository: database.media, files: try DiskFileStore(root: root))
    let input = UUID().uuidString
    let bytes = Data([1, 2, 3, 4])  // Byte-reader fixture; native decoding is separate.
    let photo = try await media.save(
        bytes, owner: .init(namespace: "photos", source: "assistant", session: "photo-session", input: input))
    let records = try AssistantRecordStore(
        repository: database.assistantMessages, tasks: database.assistantTasks,
        conversations: database.assistantConversations, logs: database.logs)
    let store = AssistantHistoryStore(records: records)
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
    let recording = try AgentModelRequestRecording(
        ChatRequest(messages: [
            .init(role: .user, content: "Photo result", images: [.init(id: photo, mimeType: "image/jpeg", data: bytes)])
        ])
    ).snapshot(initial: true)
    try await store.recordModelExchange(
        requestJSON: recording.requestJSON, response: recording.responseJSON, for: input, initial: true)
    try await store.append("Save or ignore?", to: input)
    try await store.finishModelRequest(input, reason: "stop")
    try await store.finish(input, state: .completed)
    let state = ConversationHistoryState()
    state.present(try await HistoryPresentationAdapter.listPresentation(store), status: nil)
    let workflow = ConversationHistoryWorkflow.records(
        store: store, state: state, mutate: { _, _ in })
    let conversation = try await workflow.loadConversation(initial.current.id)
    let row = try #require(ConversationHistoryPresentation.turns(conversation).first)
    let detail = try await workflow.loadMessage(row)
    #expect(detail.attachedImages.map(\.id) == [photo])
    #expect(try await workflow.imageData(photo, for: detail.id) == bytes)
    await workflow.shutdown()
    try await database.shutdown()
}

@Test @MainActor func sqlitePreviewHistoryKeepsSubmittedImageAfterSessionAndAlbumKeepsIndependentOriginal() async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try testSQLiteRepositories(root)
    let media = try fixtureMediaStore(root: root, repositories: database)
    let cache = CacheContainer()
    var previews = CameraPreviewStore(
        cache: cache.cameraImages,
        prepare: { _ in .init(data: Data([9]), width: 1, height: 1) },
        persist: { data in
            try await media.importPhoto(
                data, owner: .init(namespace: "photos", source: "album", session: "", input: ""),
                metadata: .init(mime: "image/jpeg", width: 1, height: 1, capturedAt: nil, origin: "camera"))
        })
    try previews.openSession()
    let photoScope = try #require(previews.sessionID)
    let photo = try await previews.reserve()
    let original = Data([1, 2, 3, 4])
    try await previews.publish(original, id: photo, width: 2, height: 2)
    let records = try AssistantRecordStore(
        repository: database.assistantMessages, tasks: database.assistantTasks,
        conversations: database.assistantConversations, logs: database.logs)
    let store = AssistantHistoryStore(records: records)
    let initial = try await store.readCurrent()
    for _ in 0..<2 {
        let input = UUID().uuidString
        _ = try await store.begin(
            id: input, user: "Discuss the same photo", request: [], expecting: try await store.readCurrent().token,
            model: "fixture")
        let requestJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: [
                [
                    "role": "user", "content": "Current State images",
                    "imageReferences": [
                        ["id": photo, "mimeType": "image/jpeg", "byteCount": 1, "resourceScope": photoScope]
                    ],
                ]
            ]), as: UTF8.self)
        try await store.beginModelRequest(
            .init(id: UUID().uuidString, input: "Photo", requestJSON: requestJSON), for: input)
        let recording = try AgentModelRequestRecording(
            ChatRequest(messages: [
                .init(
                    role: .user, content: "Photo", images: [.init(id: photo, mimeType: "image/jpeg", data: Data([9]))])
            ])
        ).snapshot(initial: true)
        try await store.recordModelExchange(
            requestJSON: recording.requestJSON, response: recording.responseJSON, for: input, initial: true)
        try await store.finishModelRequest(input, reason: "stop")
        try await store.finish(input, state: .completed)
    }
    let state = ConversationHistoryState()
    state.present(try await HistoryPresentationAdapter.listPresentation(store), status: nil)
    let workflow = ConversationHistoryWorkflow.records(
        store: store, state: state, mutate: { _, _ in })
    let conversation = try await workflow.loadConversation(initial.current.id)
    let rows = ConversationHistoryPresentation.turns(conversation)
    #expect(rows.count == 2)
    var detailIDs: [String] = []
    let revision = try previews.snapshot(scope: "history").revision
    for row in rows {
        let detail = try await workflow.loadMessage(row)
        detailIDs.append(detail.id)
        #expect(detail.attachedImages.map(\.id) == [photo])
        #expect(try await workflow.imageData(photo, for: detail.id) == Data([9]))
    }
    #expect(try previews.snapshot(scope: "history").revision == revision)
    #expect(try await media.albumPage().items.isEmpty)
    let saved = try await previews.save(photo)
    #expect(try previews.snapshot(scope: "history").images.isEmpty)
    #expect(try await workflow.imageData(photo, for: detailIDs[0]) == Data([9]))
    try await previews.close()
    await cache.close()
    try await database.shutdown()

    let reopened = try testSQLiteRepositories(root)
    let restored = try fixtureMediaStore(root: root, repositories: reopened)
    let nextCache = CacheContainer()
    previews = CameraPreviewStore(
        cache: nextCache.cameraImages,
        prepare: { .init(data: $0, width: 1, height: 1) },
        persist: { _ in throw RecordStorageError.invalidRecord })
    #expect(try await workflow.imageData(photo, for: detailIDs[1]) == Data([9]))
    let mediaID = try #require(saved.mediaID)
    #expect(try await restored.readAlbum(mediaID) == original)
    let record = try #require(try await reopened.media.media(mediaID))
    #expect(record.source == "album" && record.session.isEmpty && record.input.isEmpty)
    #expect(previews.cache.entries.isEmpty)
    #expect(try previews.snapshot(scope: "history").images.isEmpty)
    try previews.openSession()
    let reused = try await previews.reserve()
    #expect(reused == photo)
    #expect(throws: CameraControlError.self) { try previews.validateSession(photoScope) }
    try await previews.publish(Data([8]), id: reused, width: 1, height: 1)
    #expect(try await restored.readAlbum(mediaID) == original)
    try await restored.deleteAlbum(try #require(saved.mediaID))
    #expect(try await workflow.imageData(photo, for: detailIDs[0]) == Data([9]))
    try await previews.close()
    await nextCache.close()
    await workflow.shutdown()
    try await reopened.shutdown()
}
