import Foundation
import GRDB
import StorageChat
import StorageCore
import StorageTasks
import Testing

@testable import StorageSQLite

@Test func independentAgentTablesAndForeignKeys() async throws {
    let repository = try SQLiteRepositories.temporary()
    try repository.database.write { db throws -> Void in
        let names = Set(
            try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'"))
        #expect(
            names == [
                "assistant_conversations", "assistant_tasks", "assistant_messages", "writer_workspaces",
                "writer_messages",
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
        try WorkspaceFileRow.replace(db, taskID: 1, files: [.init(path: "original", bytes: 1, fingerprint: "original")])
    }
    #expect(throws: (any Error).self) {
        try repository.database.write { db throws -> Void in
            try WorkspaceFileRow.replace(
                db, taskID: 1,
                files: [
                    .init(path: "duplicate", bytes: 2, fingerprint: "a"),
                    .init(path: "duplicate", bytes: 3, fingerprint: "b"),
                ])
        }
    }
    let files = try repository.database.read { try WorkspaceFileRow.files($0, taskID: 1) }
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

@Test func completionOutboxRejectsStaleClaimsAndStopsAfterEightFailures() async throws {
    let repository = try SQLiteRepositories.temporary()
    let request = try await repository.seedDelegation(
        taskID: nil, goal: "work", input: "work", sourceDialog: nil, agent: "writer")
    let event = UUID().uuidString
    try await repository.writerExecutions.completeRequest(
        .init(delegateID: request.delegateID, agent: "writer", eventID: event, data: Data("{}".utf8)),
        status: "completed", failure: nil)
    var prior: String?
    for attempt in 1...8 {
        // Advance only the delivery clock; business work is never replayed.
        try repository.database.write {
            try $0.execute(sql: "UPDATE agent_messages SET next_attempt_at=0 WHERE id=?", arguments: [event])
        }
        let claimed = try #require(
            try await repository.writerExecutions.pendingTaskNotifications(
                agent: "writer", retirement: false, after: nil, limit: 1
            ).first)
        if let prior {
            await #expect(throws: RecordStorageError.conflict) {
                try await repository.writerExecutions.finishTaskNotification(
                    request.delegateID, agent: "writer", retirement: false, completed: true, failure: nil,
                    claimToken: prior)
            }
        }
        #expect(
            try await repository.writerExecutions.pendingTaskNotifications(
                agent: "writer", retirement: false, after: nil, limit: 1
            ).isEmpty)
        try await repository.writerExecutions.finishTaskNotification(
            request.delegateID, agent: "writer", retirement: false, completed: false, failure: "offline",
            claimToken: claimed.claimToken)
        prior = claimed.claimToken
        let stored = try #require(try repository.database.read { try AgentMessageRow.fetchOne($0, key: event) })
        #expect(stored.attemptCount == attempt)
        #expect(stored.deliveryState == (attempt == 8 ? "dead_letter" : "pending"))
    }
    #expect(
        try await repository.writerExecutions.pendingTaskNotifications(
            agent: "writer", retirement: false, after: nil, limit: 1
        )
        .isEmpty)
    #expect(try repository.database.read { try WriterWorkspaceRow.fetchCount($0) } == 1)
    try await repository.writerExecutions.finishTaskNotification(
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
        taskID: nil, goal: "Independent", input: "write", sourceDialog: conversation.id, agent: "writer")
    let assistant: any AssistantMessageRepository = database.assistantMessages
    let writer: any WriterMessageRepository = database.writerMessages
    let a = try await assistant.beginMessage(
        dialog: conversation.id,
        identity: .init(clientID: "same", inputID: "same", role: "user", kind: "input", order: 1, date: Date()))
    let w = try await writer.beginMessage(
        task: try await writer.current().id,
        identity: .init(clientID: "same", inputID: "same", role: "user", kind: "input", order: 1, date: Date()))
    #expect(a != w)
    #expect(try await assistant.dialogForInput("same") == conversation.id)
    #expect(try await writer.taskForInput("same") == writer.current().id)
    await #expect(throws: RecordStorageError.missingRecord) { _ = try await assistant.messageEvidence(w) }
    await #expect(throws: RecordStorageError.missingRecord) { _ = try await writer.messageEvidence(a) }
    await #expect(throws: RecordStorageError.invalidID) {
        _ = try await writer.messages(task: conversation.id, after: nil)
    }
    await #expect(throws: RecordStorageError.invalidID) {
        _ = try await assistant.messages(dialog: task.dialogID, after: nil)
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
            sql: "CREATE TABLE legacy(value TEXT); INSERT INTO legacy VALUES('old'); PRAGMA user_version=20261108")
    }
    #expect(throws: (any Error).self) {
        try SQLiteSchema.prepare(
            old, resetWriterFilesAt: try #require(URL(string: "https://invalid.example/workspaces")))
    }
    #expect(try await old.read { try String.fetchOne($0, sql: "SELECT value FROM legacy") } == "old")
    try old.close()
    let records = try SQLiteRepositories(url: url, resetWriterFilesAt: artifacts)
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
        delegateID: id, taskID: nil, goal: "Search", input: "original search", sourceDialog: "source", agent: "writer")
    let duplicate = try await records.writerExecutions.beginRequest(
        delegateID: id, taskID: nil, goal: "Changed", input: "changed", sourceDialog: nil, agent: "writer")
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
            id: supplement, sender: "assistant", receiver: "writer", contract: "task.input",
            payload: Data("{\"text\":\"blue\"}".utf8), correlationID: id, replyTo: id, dedupeKey: supplement))
    #expect(
        try await records.writerExecutions.acceptWriterInput(
            supplement, requestID: id, text: "blue", questionID: question))
    #expect(
        try await !records.writerExecutions.acceptWriterInput(
            supplement, requestID: id, text: "blue", questionID: question))
    try await records.writerExecutions.saveInteraction(delegateID: id, interactionID: nil, data: nil)
    let busy = UUID().uuidString
    try await records.agentMessages.seedAgentRequest(
        id: busy, requester: "assistant", executor: "writer", goal: "Another", input: "another", sourceDialog: nil)
    let rejected = try await records.writerExecutions.beginRequest(
        delegateID: busy, taskID: nil, goal: "Another", input: "another", sourceDialog: nil, agent: "writer")
    #expect(rejected.status == "failed" && rejected.failure != nil)
    #expect(try records.writerMessages.current().id == "writer/request_\(first.messageID)")
    #expect(try await records.writerExecutions.delegationCount() == 2)
    try await records.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    try reopened.recoverInFlight()
    #expect(try await reopened.writerExecutions.request(id, agent: "writer").status == "interrupted")
    #expect(try await reopened.writerExecutions.tasks(agent: "writer", before: nil, limit: 20).isEmpty)
    let completion = TaskNotification(
        delegateID: id, agent: "writer", eventID: UUID().uuidString, data: Data("{\"result\":\"search complete\"}".utf8)
    )
    try await reopened.writerExecutions.completeRequest(completion, status: "completed", failure: nil)
    try await reopened.writerExecutions.completeRequest(completion, status: "completed", failure: nil)
    try await reopened.logs.clearRequestLogs(agent: "writer", requestID: nil)
    let done = try await reopened.writerExecutions.request(id, agent: "writer")
    #expect(done.taskID.isEmpty && done.status == "completed" && done.result?.contains("search complete") == true)
    #expect(
        try reopened.database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM writer_messages WHERE delegation_id IS NOT NULL")
        } == 1)
    #expect(try await reopened.writerExecutions.delegationCount() == 2)
    try await reopened.shutdown()
}

@Test func writerMessageKeysIgnoreRevisionAndDeletedWorkspaceKeepsItsHistory() async throws {
    let records = try SQLiteRepositories.temporary()
    let fixture = try await records.seedDelegation(
        taskID: nil, goal: "Stable title", input: "Create", sourceDialog: nil, agent: "writer")
    try await records.writerExecutions.prepareWorkspace(
        fixture.workspaceID, taskID: fixture.id, delegateID: fixture.delegateID, agent: "writer")
    let scope = try records.writerMessages.current().id
    try records.database.write { db in
        try db.execute(sql: "UPDATE sqlite_sequence SET seq=9000000000 WHERE name='business_message'")
        try db.execute(sql: "UPDATE writer_messages SET request_revision=7 WHERE input_kind='delegation'")
    }
    let first = try records.writerMessages.beginMessage(
        task: scope,
        identity: .init(clientID: "one", inputID: "one", role: "user", kind: "input", order: 1, date: Date()))
    let second = try records.writerMessages.beginMessage(
        task: scope,
        identity: .init(clientID: "two", inputID: "two", role: "user", kind: "input", order: 1, date: Date()))
    #expect(try BusinessRecordID.number(first, kind: .message) == 9_000_000_001)
    #expect(try BusinessRecordID.number(second, kind: .message) == 9_000_000_002)
    let rows = try records.writerMessages.previews(task: fixture.workspaceID, after: 9_000_000_000, limit: 20)
    #expect(rows.map(\.position) == [9_000_000_001, 9_000_000_002])
    try await records.endSeedDelegation(fixture.delegateID, status: "completed")
    let id = try #require(WorkspaceID(rawValue: fixture.workspaceID))
    try await records.workspaces.markDeleting(id)
    try await records.workspaces.finishDeleting(id)
    #expect(try await records.writerExecutions.task(fixture.id, agent: "writer").status == "deleted")
    #expect(try records.writerMessages.timelineCount(task: fixture.workspaceID) == 2)
    let entry = try await records.writerExecutions.request(fixture.delegateID, agent: "writer")
    #expect(try records.writerMessages.timelineCount(task: "writer/preflight_\(entry.messageID)") == 0)
    await #expect(throws: RecordStorageError.conflict) {
        try await records.workspaces.claim(id, expecting: nil, lease: UUID())
    }
    try await records.shutdown()
}
