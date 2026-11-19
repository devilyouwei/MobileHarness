import Foundation
import GRDB
import StorageChat
import StorageCore
import StorageTasks
import Testing

@testable import StorageSQLite

private let writerSchemaBeforeRequestBoundary = """
    CREATE TABLE writer_messages(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    input_key TEXT NOT NULL,
    root_input_key TEXT NOT NULL,
    position INTEGER NOT NULL CHECK(position>=0),
    input_kind TEXT NOT NULL DEFAULT 'user',
    state TEXT NOT NULL DEFAULT 'generating',
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    completed_at REAL,
    schema_version INTEGER NOT NULL DEFAULT 1,
    user_input_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(user_input_json)),
    assistant_response_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(assistant_response_json)),
    tool_catalog_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(tool_catalog_json)),
    tool_calls_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(tool_calls_json)),
    workspace_id INTEGER REFERENCES writer_workspaces(id) ON DELETE RESTRICT,
    request_message_id TEXT REFERENCES agent_messages(id) ON DELETE RESTRICT,
    delegation_id INTEGER REFERENCES writer_messages(id) ON DELETE RESTRICT,
    selected_workspace_id INTEGER REFERENCES writer_workspaces(id) ON DELETE RESTRICT,
    run_state TEXT,
    request_goal TEXT,
    request_revision INTEGER NOT NULL DEFAULT 0,
    pending_question_id TEXT REFERENCES agent_messages(id) ON DELETE RESTRICT,
    pending_question_json TEXT CHECK(pending_question_json IS NULL OR json_valid(pending_question_json)),
    failure_json TEXT,
    terminal_state TEXT,
    result_json TEXT CHECK(result_json IS NULL OR json_valid(result_json)),
    caused_by_message_id INTEGER REFERENCES writer_messages(id) ON DELETE SET NULL,
    phase TEXT,
    target_path TEXT,
    runtime_results_json TEXT NOT NULL DEFAULT '[]' ,
    CHECK(request_message_id IS NOT NULL),
    CHECK((input_kind='delegation' AND delegation_id IS NULL AND workspace_id IS NULL AND run_state IS NOT NULL) OR (input_kind!='delegation' AND delegation_id IS NOT NULL AND run_state IS NULL)),
    UNIQUE(input_key));
    CREATE UNIQUE INDEX writer_delegation_identity ON writer_messages(request_message_id) WHERE input_kind='delegation';
    CREATE UNIQUE INDEX single_writer_execution ON writer_messages((1)) WHERE input_kind='delegation' AND run_state IN ('running','waiting_input','paused','closing','cleanup_failed');
    CREATE INDEX writer_message_delegation ON writer_messages(delegation_id,id);
    CREATE INDEX writer_message_order ON writer_messages(workspace_id,position,id);
    CREATE INDEX writer_message_request ON writer_messages(request_message_id,position,id);
    CREATE INDEX writer_message_root ON writer_messages(root_input_key);
    CREATE INDEX writer_message_cause ON writer_messages(caused_by_message_id);
    CREATE UNIQUE INDEX writer_message_invocation ON writer_messages(json_extract(assistant_response_json,'$.id')) WHERE json_extract(assistant_response_json,'$.id') IS NOT NULL;
    """

@Test(arguments: [20_261_110, 20_261_111])
func requestBoundaryMigrationRetainsInvocationsAndMovesWriterExecutions(version: Int) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
    let pool = try DatabasePool(path: url.path)
    try await pool.write { db in
        for statement in SQLiteSchema.statements where statement != SQLiteWriterExecutionRepository.schemaSQL {
            try db.execute(sql: statement == WriterMessageRow.schemaSQL ? writerSchemaBeforeRequestBoundary : statement)
        }
        try db.execute(sql: "INSERT INTO assistant_conversations(id,created_at) VALUES(1,1)")
        try db.execute(
            sql:
                "INSERT INTO assistant_messages(id,input_key,root_input_key,position,conversation_id,created_at,updated_at) VALUES(1,'discard','discard',1,1,1,1)"
        )
        try db.execute(
            sql:
                #"INSERT INTO assistant_messages(id,input_key,root_input_key,position,conversation_id,created_at,updated_at,state,assistant_response_json) VALUES(2,'sent','sent',2,1,2,2,'failed','{"id":"http-attempt","text":""}')"#
        )
        try db.execute(
            sql:
                "INSERT INTO model_request_log(assistant_message_id,invocation_id,method,created_at,updated_at) VALUES(2,'http-attempt','POST',2,2)"
        )
        try db.execute(
            sql:
                "INSERT INTO agent_messages(id,sender_agent_id,receiver_agent_id,contract,payload_json,correlation_id,dedupe_key,created_at) VALUES('delegate','assistant','writer','task.request','{}','delegate','delegate',1)"
        )
        try db.execute(sql: "INSERT INTO writer_workspaces(id,description,created_at,updated_at) VALUES(1,'draft',1,1)")
        try db.execute(
            sql:
                #"INSERT INTO writer_messages(id,input_key,root_input_key,position,input_kind,request_message_id,selected_workspace_id,request_goal,run_state,user_input_json,result_json,created_at,updated_at) VALUES(10,'delegate','delegate',10,'delegation','delegate',1,'goal','completed','{"text":"write","source_agent":"assistant"}','{"result":"kept"}',1,1)"#
        )
        try db.execute(
            sql:
                #"INSERT INTO writer_messages(id,input_key,root_input_key,position,delegation_id,workspace_id,request_message_id,assistant_response_json,created_at,updated_at) VALUES(11,'writer-input','writer-input',11,10,1,'delegate','{"id":"writer-http","text":"reply"}',2,2)"#
        )
        try db.execute(
            sql:
                "INSERT INTO writer_messages(id,input_key,root_input_key,position,delegation_id,request_message_id,created_at,updated_at) VALUES(12,'queued','queued',12,10,'delegate',3,3)"
        )
        try db.execute(
            sql:
                "INSERT INTO model_request_log(writer_message_id,invocation_id,method,created_at,updated_at) VALUES(11,'writer-http','POST',2,2)"
        )
        try db.execute(sql: "PRAGMA user_version=\(version)")
    }
    try SQLiteSchema.prepare(pool)
    try await pool.read { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assistant_messages") == 1)
        #expect(try String.fetchOne(db, sql: "SELECT state FROM assistant_messages WHERE id=2") == "failed")
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM writer_messages") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT delegation_id FROM writer_messages WHERE id=11") == 10)
        #expect(
            try String.fetchOne(db, sql: "SELECT result_json FROM writer_executions WHERE id=10")
                == #"{"result":"kept"}"#)
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM model_request_log") == 2)
        #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SQLiteSchema.currentVersion)
        #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
    try SQLiteSchema.prepare(pool)
    try pool.close()
}

@Test func taskContractMigrationRetainsPendingWriterResponse() async throws {
    let repository = try SQLiteRepositories.temporary()
    let request = try await repository.seedDelegation(
        workspaceID: nil, goal: "work", input: "work", sourceDialog: nil, agent: "writer")
    let event = UUID().uuidString
    let payload = Data("{}".utf8)
    try await repository.writerExecutions.completeRequest(
        .init(delegateID: request.delegateID, agent: "writer", eventID: event, data: payload),
        status: "completed", failure: nil)
    try repository.database.write { db in
        try db.execute(
            sql: "UPDATE agent_messages SET contract='agent.task.message' WHERE id=?",
            arguments: [request.delegateID])
        try db.execute(
            sql: "UPDATE agent_messages SET contract='agent.task.report' WHERE id=?", arguments: [event])
        try db.execute(sql: "PRAGMA user_version=20261112")
    }

    try repository.database.prepareSchema { try SQLiteSchema.prepare($0) }
    try repository.database.prepareSchema { try SQLiteSchema.prepare($0) }
    let original = try #require(try await repository.agentMessages.agentMessage(request.delegateID))
    #expect(original.contract == "agent.task.request")
    let stored = try #require(try await repository.agentMessages.agentMessage(event))
    #expect(stored.contract == "agent.task.response")
    #expect(stored.replyTo == original.id)
    #expect(stored.payload == payload)
    let pending = try await repository.writerExecutions.pendingDelegationNotifications(
        agent: "writer", retirement: false, after: nil, limit: 1)
    #expect(pending.first?.eventID == event)
    try await repository.shutdown()
}

@Test func independentAgentTablesAndForeignKeys() async throws {
    let repository = try SQLiteRepositories.temporary()
    try repository.database.write { db throws -> Void in
        let names = Set(
            try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'"))
        #expect(
            names == [
                "assistant_conversations", "assistant_tasks", "assistant_messages", "writer_workspaces",
                "writer_messages", "writer_executions",
                "workspace_files", "agent_messages", "model_request_log", "media_files", "devices",
            ])
        var conversation = AssistantConversationRow(createdAt: 1)
        try conversation.insert(db)
        var foreground = AssistantTaskRow(conversationID: conversation.id!, description: "First", startedAt: 1)
        try foreground.insert(db)
        #expect(throws: (any Error).self) {
            var nested = AssistantTaskRow(conversationID: conversation.id!, description: "Nested", startedAt: 2)
            try nested.insert(db)
        }
        var writer = WriterWorkspaceRow(description: "Independent", createdAt: 1, updatedAt: 1)
        try writer.insert(db)
        var message = AssistantMessageRow(
            inputKey: "input", rootInputKey: "input", position: 1, createdAt: 1, updatedAt: 1,
            conversationID: conversation.id!, taskID: foreground.id)
        try message.insert(db)
        var log = ModelRequestLogRow(
            assistantMessageID: message.id, invocationID: "http", requestBody: Data([0, 255]),
            responseBody: Data([0, 128]), createdAt: 1, updatedAt: 1)
        try log.insert(db)
        let restored = try #require(try ModelRequestLogRow.fetchOne(db, key: log.id))
        #expect(restored.responseBody == Data([0, 128]))
        try db.execute(sql: "DELETE FROM model_request_log")
        #expect(try AssistantMessageRow.fetchCount(db) == 1)
        try db.execute(sql: "DELETE FROM assistant_conversations")
        #expect(try AssistantTaskRow.fetchCount(db) == 0)
        #expect(try AssistantMessageRow.fetchCount(db) == 0)
        #expect(try WriterWorkspaceRow.fetchCount(db) == 1)
        #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
    try await repository.shutdown()
}

@Test func workspaceIndexReplacementRollsBackWhenACompositeKeyIsDuplicated() async throws {
    let repository = try SQLiteRepositories.temporary()
    try repository.database.write { db throws -> Void in
        var task = WriterWorkspaceRow(description: "draft", createdAt: 1, updatedAt: 1)
        try task.insert(db)
        try WorkspaceFileRow.replace(
            db, workspaceID: 1, files: [.init(path: "original", bytes: 1, fingerprint: "original")])
    }
    #expect(throws: (any Error).self) {
        try repository.database.write { db throws -> Void in
            try WorkspaceFileRow.replace(
                db, workspaceID: 1,
                files: [
                    .init(path: "duplicate", bytes: 2, fingerprint: "a"),
                    .init(path: "duplicate", bytes: 3, fingerprint: "b"),
                ])
        }
    }
    let files = try repository.database.read { try WorkspaceFileRow.files($0, workspaceID: 1) }
    #expect(files.count == 1 && files.first?.path == "original")
    try await repository.shutdown()
}

@Test func oldFormatIsErasedAndCurrentFormatSurvivesReopening() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
    let old = try DatabaseQueue(path: url.path)
    try await old.write { db in
        try db.execute(
            sql: "CREATE TABLE messages(body TEXT); INSERT INTO messages VALUES ('obsolete'); PRAGMA user_version=1")
    }
    try old.close()
    let first = try SQLiteRepositories(url: url)
    let conversation = try await first.assistantConversations.current()
    try first.database.read { db throws -> Void in
        #expect(try !db.tableExists("messages"))
        #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SQLiteSchema.currentVersion)
    }
    try await first.shutdown()
    let second = try SQLiteRepositories(url: url)
    #expect(try await second.assistantConversations.current().id == conversation.id)
    try await second.shutdown()
}

@Test func futureDatabaseVersionIsRejectedWithoutErasing() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
    let pool = try DatabasePool(path: url.path)
    try pool.write { db in
        try db.execute(
            sql:
                "CREATE TABLE retained(value TEXT); INSERT INTO retained VALUES ('keep'); PRAGMA user_version=2147483647"
        )
    }
    #expect(throws: SQLiteSchemaError.unsupportedVersion(2_147_483_647)) { try SQLiteSchema.prepare(pool) }
    #expect(try pool.read { try String.fetchOne($0, sql: "SELECT value FROM retained") } == "keep")
    try pool.close()
}

@Test func rawHTTPAttemptsPreserveBytesAndCannotResurrectAfterDeletion() async throws {
    let repository = try SQLiteRepositories.temporary()
    let logs: any ModelRequestLogRepository = repository.logs
    let conversation = try await repository.assistantConversations.current()
    let invocation = UUID().uuidString
    let message = try repository.assistantMessages.beginMessage(
        dialog: conversation.id,
        identity: .init(
            clientID: invocation, inputID: "raw-input", role: "assistant", kind: "response", order: 1, date: Date()))
    let body = Data(
        "{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"data:image/jpeg;base64,AQID\"}]}]}"
            .utf8)
    let response = Data("data: {\"delta\":\"中文\"}\r\n\r\n".utf8)
    for status in [503, 200] {
        try await logs.writeRequestPayload(
            invocation, agent: "assistant", json: "", response: "", initial: false,
            update: .request(
                method: "POST", url: "https://example.test/responses", headers: [:], body: body, at: Date()))
        try await logs.writeRequestPayload(
            invocation, agent: "assistant", json: "", response: "", initial: false,
            update: .response(status: status, headers: ["Content-Type": "text/event-stream"], at: Date()))
        for chunk in [response.prefix(7), response.dropFirst(7)] {
            try await logs.writeRequestPayload(
                invocation, agent: "assistant", json: "", response: "", initial: false,
                update: .bytes(Data(chunk), at: Date()))
        }
        try await logs.writeRequestPayload(
            invocation, agent: "assistant", json: "", response: "", initial: false,
            update: .finished(at: Date(), error: nil))
    }
    let captures = try repository.database.read {
        try ModelRequestLogRow.fetchAll($0, sql: "SELECT * FROM model_request_log ORDER BY transport_index")
    }
    #expect(captures.map(\.httpStatus) == [503, 200])
    #expect(
        captures.allSatisfy { $0.requestBody == body && $0.responseBody == response && $0.captureState == "completed" })
    try await logs.clearRequestLogs(agent: "assistant", requestID: message)
    try await logs.writeRequestPayload(
        invocation, agent: "assistant", json: "", response: "", initial: true,
        update: .request(method: "POST", url: "https://example.test", headers: [:], body: body, at: Date()))
    #expect(try repository.database.read { try ModelRequestLogRow.fetchCount($0) } == 0)
    #expect(try repository.database.read { try AssistantMessageRow.fetchCount($0) } == 1)
    try await repository.shutdown()
}

@Test(arguments: ["agent.task.response", "writer.completion"])
func completionOutboxRejectsStaleClaimsAndStopsAfterEightFailures(contract: String) async throws {
    let repository = try SQLiteRepositories.temporary()
    let request = try await repository.seedDelegation(
        workspaceID: nil, goal: "work", input: "work", sourceDialog: nil, agent: "writer")
    let event = UUID().uuidString
    try await repository.writerExecutions.completeRequest(
        .init(delegateID: request.delegateID, agent: "writer", eventID: event, data: Data("{}".utf8)),
        status: "completed", failure: nil)
    if contract == "writer.completion" {
        try repository.database.write {
            try $0.execute(sql: "UPDATE agent_messages SET contract=? WHERE id=?", arguments: [contract, event])
        }
    }
    #expect(try await repository.agentMessages.agentMessage(event)?.contract == contract)
    var prior: String?
    for attempt in 1...8 {
        // Advance only the delivery clock; business work is never replayed.
        try repository.database.write {
            try $0.execute(sql: "UPDATE agent_messages SET next_attempt_at=0 WHERE id=?", arguments: [event])
        }
        let claimed = try #require(
            try await repository.writerExecutions.pendingDelegationNotifications(
                agent: "writer", retirement: false, after: nil, limit: 1
            ).first)
        if let prior {
            await #expect(throws: RecordStorageError.conflict) {
                try await repository.writerExecutions.finishDelegationNotification(
                    request.delegateID, agent: "writer", retirement: false, completed: true, failure: nil,
                    claimToken: prior)
            }
        }
        #expect(
            try await repository.writerExecutions.pendingDelegationNotifications(
                agent: "writer", retirement: false, after: nil, limit: 1
            ).isEmpty)
        try await repository.writerExecutions.finishDelegationNotification(
            request.delegateID, agent: "writer", retirement: false, completed: false, failure: "offline",
            claimToken: claimed.claimToken)
        prior = claimed.claimToken
        let stored = try #require(try repository.database.read { try AgentMessageRow.fetchOne($0, key: event) })
        #expect(stored.attemptCount == attempt)
        #expect(stored.deliveryState == (attempt == 8 ? "dead_letter" : "pending"))
    }
    #expect(
        try await repository.writerExecutions.pendingDelegationNotifications(
            agent: "writer", retirement: false, after: nil, limit: 1
        )
        .isEmpty)
    #expect(try repository.database.read { try WriterWorkspaceRow.fetchCount($0) } == 1)
    try await repository.writerExecutions.finishDelegationNotification(
        request.delegateID, agent: "writer", retirement: true, completed: true, failure: nil)
    #expect(try await repository.writerExecutions.request(request.delegateID, agent: "writer").status == "completed")
    try await repository.shutdown()
}

@Test func narrowTaskAndCommunicationPortsPreserveTheirIndependentState() async throws {
    let repositories = try SQLiteRepositories.temporary()
    let foreground: any AssistantTaskRepository = repositories.assistantTasks
    let communication: any AgentMessageRepository = repositories.agentMessages
    let conversation = try repositories.assistantConversations.current()
    let task = try await foreground.createTask(dialog: conversation.id, agent: "assistant", goal: "Foreground")
    let id = UUID().uuidString
    let value = AgentCommunicationRecord(
        id: id, sender: "assistant", receiver: "writer", contract: "task.delegate",
        payload: Data("{\"description\":\"Independent work\"}".utf8), correlationID: id, dedupeKey: id)
    try await communication.enqueueAgentMessage(value)
    try await communication.enqueueAgentMessage(value)
    try await communication.receiveAgentMessage(id, receiver: "writer", consumed: true)
    let stored = try await communication.agentMessage(id)
    #expect(stored?.id == id && stored?.receiver == "writer")
    try await foreground.endTask(task, status: "completed")
    let facts = try repositories.database.read { db in
        (
            try String.fetchOne(db, sql: "SELECT state FROM assistant_tasks"),
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM writer_workspaces"),
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_messages WHERE consumed_at IS NOT NULL")
        )
    }
    #expect(facts.0 == "completed" && facts.1 == 0 && facts.2 == 1)
    await #expect(throws: RecordStorageError.missingRecord) {
        try await communication.receiveAgentMessage(id, receiver: "other", consumed: true)
    }
    try await repositories.shutdown()
}

@Test func privateMessagePortsRejectOtherAgentAddressesAndAllowRepeatedInputKeys() async throws {
    let database = try SQLiteRepositories.temporary()
    let conversation = try database.assistantConversations.current()
    let task = try await database.seedDelegation(
        workspaceID: nil, goal: "Independent", input: "write", sourceDialog: conversation.id, agent: "writer")
    let assistant: any AssistantMessageRepository = database.assistantMessages
    let writer: any WriterMessageRepository = database.writerMessages
    let a = try await assistant.beginMessage(
        dialog: conversation.id,
        identity: .init(clientID: "same", inputID: "same", role: "user", kind: "input", order: 1, date: Date()))
    let w = try await writer.beginMessage(
        ownerID: try await writer.current().id,
        identity: .init(clientID: "same", inputID: "same", role: "user", kind: "input", order: 1, date: Date()))
    #expect(a != w)
    #expect(try await assistant.dialogForInput("same") == conversation.id)
    #expect(try await writer.taskForInput("same") == writer.current().id)
    await #expect(throws: RecordStorageError.missingRecord) { _ = try await assistant.messageEvidence(w) }
    await #expect(throws: RecordStorageError.missingRecord) { _ = try await writer.messageEvidence(a) }
    await #expect(throws: RecordStorageError.invalidID) {
        _ = try await writer.messages(ownerID: conversation.id, after: nil)
    }
    await #expect(throws: RecordStorageError.invalidID) {
        _ = try await assistant.messages(dialog: task.workspaceID, after: nil)
    }
    try await database.shutdown()
}

@Test func assistantStateSelectionSurvivesPersistenceAndRequestLogDeletion() async throws {
    let repository = try SQLiteRepositories.temporary()
    let conversation = try await repository.assistantConversations.current()
    let invocation = UUID().uuidString
    let metadata = AssistantDecisionMetadata(
        taskID: nil, mode: "default", skills: ["basic": 1], catalogJSON: #"{"actions":[],"tools":[]}"#,
        states: ["ui.navigation", "platform.device"])
    let request = AssistantModelRequest(
        id: invocation, input: "fixture", requestJSON: "[]", decisionMetadata: metadata)
    let message = try repository.assistantMessages.beginMessage(
        dialog: conversation.id,
        identity: .init(
            clientID: invocation, inputID: "state-input", role: "assistant", kind: "response", order: 1, date: Date()))
    try await repository.assistantMessages.save(
        dialog: conversation.id, revision: 1,
        messages: [
            .init(
                clientID: invocation, inputID: "state-input", role: "assistant", kind: "response", order: 1,
                date: request.date, body: "reply", state: "completed", detail: try JSONEncoder().encode(request))
        ], summaries: [])
    for cleared in [false, true] {
        if cleared { try await repository.logs.clearRequestLogs(agent: "assistant", requestID: message) }
        let evidence = try await repository.assistantMessages.messageEvidence(message)
        let response = try #require(evidence.first(where: { $0.role == "assistant" }))
        let restored = try JSONDecoder().decode(AssistantModelRequest.self, from: response.detail)
        #expect(restored.decisionMetadata?.states == metadata.states)
        #expect(restored.decisionMetadata?.skills == metadata.skills)
    }
    try await repository.shutdown()
}

@Test func writerSchemaResetRemovesOnlyApprovedFilesAndFailsBeforeChangingDatabase() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("records.sqlite")
    let artifacts = root.appendingPathComponent("ArtifactWorkspaces")
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try Data("old preview".utf8).write(to: artifacts.appendingPathComponent("preview.html"))
    let config = root.appendingPathComponent("configuration.json")
    try Data("preserved".utf8).write(to: config)
    let old = try DatabasePool(path: url.path)
    try await old.write { db in
        try db.execute(
            sql: "CREATE TABLE legacy(value TEXT); INSERT INTO legacy VALUES('old'); PRAGMA user_version=20261109")
    }
    #expect(throws: (any Error).self) {
        try SQLiteSchema.prepare(
            old, resetWriterFilesAt: try #require(URL(string: "https://invalid.example/workspaces")))
    }
    #expect(try await old.read { try String.fetchOne($0, sql: "SELECT value FROM legacy") } == "old")
    try old.close()
    let records = try SQLiteRepositories(url: url, resetWriterFilesAt: artifacts)
    let fileColumns = try records.database.read { db in try db.columns(in: "workspace_files").map(\.name) }
    #expect(fileColumns.contains("workspace_id") && !fileColumns.contains("task_id"))
    #expect(!FileManager.default.fileExists(atPath: artifacts.path))
    #expect(try String(contentsOf: config, encoding: .utf8) == "preserved")
    #expect(
        try records.database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_schema WHERE name='legacy'")
        } == 0)
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: artifacts.appendingPathComponent("keep.md"))
    try await records.shutdown()
    let reopened = try SQLiteRepositories(url: url, resetWriterFilesAt: artifacts)
    #expect(FileManager.default.fileExists(atPath: artifacts.appendingPathComponent("keep.md").path))
    try await reopened.shutdown()
}

@Test func writerEntriesAreUniqueAndRecoveryDoesNotInventWorkspaceMessages() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let records = try SQLiteRepositories(url: url)
    let id = UUID().uuidString
    try await records.agentMessages.seedAgentRequest(
        id: id, requester: "assistant", executor: "writer", goal: "Search", input: "original search",
        sourceDialog: "source")
    let first = try await records.writerExecutions.beginRequest(
        delegateID: id, workspaceID: nil, goal: "Search", input: "original search", sourceDialog: "source",
        agent: "writer")
    let duplicate = try await records.writerExecutions.beginRequest(
        delegateID: id, workspaceID: nil, goal: "Changed", input: "changed", sourceDialog: nil, agent: "writer")
    #expect(first.messageID == duplicate.messageID && duplicate.input == "original search")
    let question = UUID().uuidString
    try await records.writerExecutions.saveInteraction(
        delegateID: id, interactionID: question,
        data: Data("{\"text\":\"Which color?\",\"stage\":\"waitingUser\"}".utf8))
    let waiting = try await records.writerExecutions.request(id, agent: "writer")
    #expect(waiting.executionState == "waiting_input" && waiting.waiting?.contains("Which color?") == true)
    let supplement = UUID().uuidString
    try await records.agentMessages.enqueueAgentMessage(
        .init(
            id: supplement, sender: "assistant", receiver: "writer", contract: "agent.task.request",
            payload: Data("{\"text\":\"blue\"}".utf8), correlationID: id, replyTo: id, dedupeKey: supplement))
    #expect(
        try await records.writerExecutions.acceptWriterInput(
            supplement, requestID: id, questionID: question))
    #expect(
        try await !records.writerExecutions.acceptWriterInput(
            supplement, requestID: id, questionID: question))
    try await records.writerExecutions.saveInteraction(delegateID: id, interactionID: nil, data: nil)
    let busy = UUID().uuidString
    try await records.agentMessages.seedAgentRequest(
        id: busy, requester: "assistant", executor: "writer", goal: "Another", input: "another", sourceDialog: nil)
    let rejected = try await records.writerExecutions.beginRequest(
        delegateID: busy, workspaceID: nil, goal: "Another", input: "another", sourceDialog: nil, agent: "writer")
    #expect(rejected.status == "failed" && rejected.failure != nil)
    #expect(try records.writerMessages.current().id == "writer/request_\(first.messageID)")
    #expect(try await records.writerExecutions.delegationCount() == 2)
    try await records.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    try reopened.recoverInFlight()
    #expect(try await reopened.writerExecutions.request(id, agent: "writer").status == "interrupted")
    #expect(try await reopened.writerExecutions.workspaces(agent: "writer", before: nil, limit: 20).isEmpty)
    let completion = WriterDelegationNotification(
        delegateID: id, agent: "writer", eventID: UUID().uuidString, data: Data("{\"result\":\"search complete\"}".utf8)
    )
    try await reopened.writerExecutions.completeRequest(completion, status: "completed", failure: nil)
    try await reopened.writerExecutions.completeRequest(completion, status: "completed", failure: nil)
    try await reopened.logs.clearRequestLogs(agent: "writer", requestID: nil)
    let done = try await reopened.writerExecutions.request(id, agent: "writer")
    #expect(done.workspaceID.isEmpty && done.status == "completed" && done.result?.contains("search complete") == true)
    #expect(
        try reopened.database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM writer_messages WHERE delegation_id IS NOT NULL")
        } == 0)
    #expect(try await reopened.writerExecutions.delegationCount() == 2)
    try await reopened.shutdown()
}

@Test func writerMessageKeysIgnoreRevisionAndDeletedWorkspaceKeepsItsHistory() async throws {
    let records = try SQLiteRepositories.temporary()
    let fixture = try await records.seedDelegation(
        workspaceID: nil, goal: "Stable title", input: "Create", sourceDialog: nil, agent: "writer")
    try await records.writerExecutions.prepareWorkspace(
        workspaceID: fixture.id, delegateID: fixture.delegateID, agent: "writer")
    let scope = try records.writerMessages.current().id
    try records.database.write { db in
        try db.execute(sql: "UPDATE sqlite_sequence SET seq=9000000000 WHERE name='business_message'")
        try db.execute(sql: "UPDATE writer_executions SET request_revision=7")
    }
    let first = try records.writerMessages.beginMessage(
        ownerID: scope,
        identity: .init(clientID: "one", inputID: "one", role: "assistant", kind: "response", order: 1, date: Date()))
    let second = try records.writerMessages.beginMessage(
        ownerID: scope,
        identity: .init(clientID: "two", inputID: "two", role: "assistant", kind: "response", order: 1, date: Date()))
    #expect(try BusinessRecordID.number(first, kind: .request) == 9_000_000_001)
    #expect(try BusinessRecordID.number(second, kind: .request) == 9_000_000_002)
    let rows = try records.writerMessages.previews(ownerID: fixture.workspaceID, after: 9_000_000_000, limit: 20)
    #expect(rows.map(\.position) == [9_000_000_001, 9_000_000_002])
    try await records.endSeedDelegation(fixture.delegateID, status: "completed")
    let id = try #require(WorkspaceID(rawValue: fixture.workspaceID))
    try await records.workspaces.markDeleting(id)
    try await records.workspaces.finishDeleting(id)
    #expect(try await records.writerExecutions.workspace(fixture.id, agent: "writer").status == "deleted")
    #expect(try records.writerMessages.timelineCount(ownerID: fixture.workspaceID) == 2)
    let entry = try await records.writerExecutions.request(fixture.delegateID, agent: "writer")
    #expect(try records.writerMessages.timelineCount(ownerID: "writer/preflight_\(entry.messageID)") == 0)
    await #expect(throws: RecordStorageError.conflict) {
        try await records.workspaces.claim(id, expecting: nil, lease: UUID())
    }
    try await records.shutdown()
}

@Test func assistantMessagesStartAtDispatchAndDiscardNeverPersists() async throws {
    let db = try SQLiteRepositories.temporary()
    let records = try AssistantRecordStore(
        repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
        logs: db.logs)
    let store = AssistantHistoryStore(records: records)
    let current = try await store.readCurrent()
    _ = try await store.admitUserInput(id: "discard", user: "ack", model: "not started")
    var discarded = AssistantInputCoordination(source: "speech", capturedAt: "1")
    discarded.decision = "discard"
    try await store.recordCoordination(discarded, for: "discard")
    try await store.finish("discard", state: .completed, reason: "decision.discard")
    #expect(try db.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM assistant_messages") } == 0)
    #expect(try db.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM model_request_log") } == 0)
    _ = try await store.admitUserInput(id: "cancelled", user: "cancel before send", model: "cloud")
    try await store.beginModelRequest(
        .init(id: "never-started", input: "cancel before send", requestJSON: "[]"), for: "cancelled",
        awaitingDispatch: true)
    try await store.finish("cancelled", state: .cancelled)
    await #expect(throws: (any Error).self) { try await store.markModelRequestDispatched("cancelled") }
    #expect(try db.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM assistant_messages") } == 0)
    _ = try await store.admitUserInput(id: "a", user: "one", model: "cloud")
    _ = try await store.admitUserInput(id: "b", user: "two", model: "cloud")
    try await store.beginModelRequest(
        .init(id: "call", input: "one + two", requestJSON: "[]"), for: "a", awaitingDispatch: true)
    try await store.checkpoint()
    #expect(try db.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM assistant_messages") } == 0)
    try await store.markModelRequestDispatched("a")
    try await store.markModelRequestDispatched("a")
    #expect(try db.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM assistant_messages") } == 1)
    try await store.finishModelRequest("a", reason: "error", error: "network timeout")
    try await store.finish("a", state: .failed, error: "network timeout")
    try await store.finish("b", state: .failed, error: "batch request failed")
    let rows = try await records.page(current.current.id)
    #expect(rows.turns.count == 1 && rows.turns.first?.modelRequests?.first?.state == .failed)
    #expect(rows.turns.first?.modelRequests?.first?.input == "one + two")
    #expect(try db.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM assistant_messages") } == 1)
    try await db.shutdown()
}

@Test func writerDelegationAndPreparationDoNotCreateMessagesUntilDispatch() async throws {
    let db = try SQLiteRepositories.temporary()
    _ = try await db.seedDelegation(
        workspaceID: nil, goal: "create", input: "write", sourceDialog: nil, agent: "writer")
    let records = try WriterRecordStore(repository: db.writerMessages, logs: db.logs)
    let store = WriterHistoryStore(records: records)
    let read = try await store.readCurrent()
    _ = try await store.begin(id: "prepare", user: "write", request: [], expecting: read.token, model: "cloud")
    try await store.beginModelRequest(
        .init(id: "never-sent", input: "write", requestJSON: "[]"), for: "prepare", awaitingDispatch: true)
    try await store.finish("prepare", state: .failed, error: "configuration rejected before HTTP")
    await #expect(throws: (any Error).self) { try await store.markModelRequestDispatched("prepare") }
    #expect(try db.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM writer_executions") } == 1)
    #expect(try db.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM writer_messages") } == 0)
    #expect(try db.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM model_request_log") } == 0)
    _ = try await store.begin(
        id: "sent", user: "write", request: [], expecting: store.readCurrent().token, model: "cloud")
    try await store.beginModelRequest(
        .init(id: "writer-http", input: "write", requestJSON: "[]"), for: "sent", awaitingDispatch: true)
    try await store.markModelRequestDispatched("sent")
    try await store.finish("sent", state: .failed, error: "connection reset")
    #expect(try db.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM writer_messages") } == 1)
    #expect(try db.database.read { try String.fetchOne($0, sql: "SELECT state FROM writer_messages") } == "failed")
    #expect(try db.database.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty)
    try await db.shutdown()
}
