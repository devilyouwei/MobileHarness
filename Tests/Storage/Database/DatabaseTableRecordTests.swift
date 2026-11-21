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
                "writer_messages", "writer_executions",
                "workspace_files", "agent_messages", "model_request_log", "media_files", "devices",
                "invocation_evidence",
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

@Test func otherDatabaseVersionIsReplacedWithoutMigration() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
    let pool = try DatabasePool(path: url.path)
    try pool.write { db in
        try db.execute(
            sql:
                "CREATE TABLE retained(value TEXT); INSERT INTO retained VALUES ('drop'); PRAGMA user_version=2147483647"
        )
    }
    try SQLiteSchema.prepare(pool)
    try pool.read { db throws -> Void in
        #expect(try !db.tableExists("retained"))
        #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SQLiteSchema.currentVersion)
    }
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

@Test func completionWritesOnlyWriterExecutionAndRetirementRecordsCleanup() async throws {
    let repository = try SQLiteRepositories.temporary()
    let request = try await repository.seedDelegation(
        workspaceID: nil, goal: "work", input: "work", sourceDialog: nil, agent: "writer")
    let event = UUID().uuidString
    try await repository.writerExecutions.completeRequest(
        request.delegateID, eventID: event, result: Data("{}".utf8), status: "completed", failure: nil,
        cancellationReason: nil)
    #expect(try await repository.agentMessages.agentMessage(event) == nil)
    await #expect(throws: RecordStorageError.conflict) {
        try await repository.writerExecutions.completeRequest(
            request.delegateID, eventID: UUID().uuidString, result: Data("{}".utf8), status: "failed",
            failure: "late", cancellationReason: nil)
    }
    try await repository.writerExecutions.retireRequest(request.delegateID, failure: "grant busy")
    #expect(
        try await repository.writerExecutions.request(request.delegateID, agent: "writer").retirement
            == "failed")
    try await repository.writerExecutions.retireRequest(request.delegateID, failure: nil)
    #expect(try await repository.writerExecutions.request(request.delegateID, agent: "writer").status == "completed")
    #expect(
        try await repository.writerExecutions.request(request.delegateID, agent: "writer").retirement == "done")
    await #expect(throws: RecordStorageError.conflict) {
        try await repository.writerExecutions.completeRequest(
            request.delegateID, eventID: UUID().uuidString, result: Data("{}".utf8), status: "failed",
            failure: "after end", cancellationReason: nil)
    }
    try await repository.shutdown()
}

private func beginNext(_ records: SQLiteRepositories) async throws -> WriterRequestRecord {
    let id = UUID().uuidString
    try await records.agentMessages.seedAgentRequest(
        id: id, requester: "assistant", executor: "writer", goal: "next", input: "next", sourceDialog: nil)
    return try await records.writerExecutions.beginRequest(
        delegateID: id, workspaceID: nil, goal: "next", input: "next", sourceDialog: nil, agent: "writer")
}

@Test func recoveryReleasesFailedRetirement() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let records = try SQLiteRepositories(url: url)
    let request = try await records.seedDelegation(
        workspaceID: nil, goal: "work", input: "work", sourceDialog: nil, agent: "writer")
    try await records.writerExecutions.completeRequest(
        request.delegateID, eventID: UUID().uuidString, result: Data("{}".utf8), status: "completed", failure: nil,
        cancellationReason: nil)
    try await records.writerExecutions.retireRequest(request.delegateID, failure: "grant busy")
    let blocked = try await beginNext(records)
    #expect(blocked.status == "failed")
    try await records.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    try reopened.recoverInFlight()
    let recovered = try await reopened.writerExecutions.request(request.delegateID, agent: "writer")
    #expect(recovered.retirement == "done" && recovered.status == "completed")
    #expect(try await beginNext(reopened).status == "running")
    try await reopened.shutdown()
}

@Test func restartInterruptedDelegationAcceptsExactlyOneCompletion() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let records = try SQLiteRepositories(url: url)
    let request = try await records.seedDelegation(
        workspaceID: nil, goal: "work", input: "work", sourceDialog: nil, agent: "writer")
    try await records.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    try reopened.recoverInFlight()
    let interrupted = try await reopened.writerExecutions.request(request.delegateID, agent: "writer")
    #expect(interrupted.status == "interrupted" && interrupted.taskState == "interrupted")
    #expect(interrupted.retirement == "done")
    try await reopened.writerExecutions.completeRequest(
        request.delegateID, eventID: UUID().uuidString, result: Data("{}".utf8), status: "interrupted",
        failure: "restart", cancellationReason: nil)
    await #expect(throws: RecordStorageError.conflict) {
        try await reopened.writerExecutions.completeRequest(
            request.delegateID, eventID: UUID().uuidString, result: Data("{}".utf8), status: "failed",
            failure: "again", cancellationReason: nil)
    }
    try await reopened.shutdown()
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
    #expect(waiting.status == "running" && waiting.waiting?.contains("Which color?") == true)
    let supplement = UUID().uuidString
    try await records.agentMessages.enqueueAgentMessage(
        .init(
            id: supplement, sender: "assistant", receiver: "writer", contract: "agent.task.v1",
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
    try await reopened.writerExecutions.completeRequest(
        id, eventID: UUID().uuidString, result: Data("{\"result\":\"search complete\"}".utf8), status: "completed",
        failure: nil, cancellationReason: nil)
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
    #expect(try records.writerMessages.timelineCount(ownerID: WriterPreflightOwner.id(entry.messageID)) == 0)
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

@Test func invocationEvidenceIsImmutableAndRecoverable() async throws {
    let repository = try SQLiteRepositories.temporary()
    let id = UUID().uuidString
    let original = Data("original arguments".utf8)
    try await repository.agentMessages.archiveInvocationEvidence(id, ownerContext: "session", data: original)
    try await repository.agentMessages.archiveInvocationEvidence(id, ownerContext: "session", data: original)
    #expect(try await repository.agentMessages.invocationEvidence(id) == original)
    await #expect(throws: RecordStorageError.conflict) {
        try await repository.agentMessages.archiveInvocationEvidence(id, ownerContext: "other", data: original)
    }
    await #expect(throws: RecordStorageError.conflict) {
        try await repository.agentMessages.archiveInvocationEvidence(
            id, ownerContext: "session", data: Data("changed".utf8))
    }
    try await repository.shutdown()
}

@Test func writerTaskProtocolUsesOriginalRequesterInsteadOfASenderPair() async throws {
    let repository = try SQLiteRepositories.temporary()
    let root = UUID().uuidString
    try await repository.agentMessages.enqueueAgentMessage(
        .init(
            id: root, sender: "memory", receiver: "writer", contract: "agent.task.v1", payload: Data("{}".utf8),
            correlationID: root, sourceSessionID: "session", dedupeKey: root))
    _ = try await repository.writerExecutions.beginRequest(
        delegateID: root, workspaceID: nil, goal: "work", input: "work", sourceDialog: nil, agent: "writer")
    let outsider = UUID().uuidString
    try await repository.agentMessages.enqueueAgentMessage(
        .init(
            id: outsider, sender: "photographer", receiver: "writer", contract: "agent.task.v1",
            payload: Data("{}".utf8), correlationID: root, replyTo: root, sourceSessionID: "session",
            dedupeKey: outsider))
    await #expect(throws: RecordStorageError.conflict) {
        try await repository.writerExecutions.acceptWriterInput(outsider, requestID: root, questionID: nil)
    }
    let update = UUID().uuidString
    try await repository.agentMessages.enqueueAgentMessage(
        .init(
            id: update, sender: "memory", receiver: "writer", contract: "agent.task.v1", payload: Data("{}".utf8),
            correlationID: root, replyTo: root, sourceSessionID: "session", dedupeKey: update))
    #expect(try await repository.writerExecutions.acceptWriterInput(update, requestID: root, questionID: nil))
    try await repository.shutdown()
}
