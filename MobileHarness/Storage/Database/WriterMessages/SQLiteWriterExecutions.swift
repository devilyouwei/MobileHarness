import Foundation
internal import GRDB
import StorageCore
import StorageTasks

extension SQLiteWriterExecutionRepository {
    /// Writes are single-flight until the execution grant is retired.
    static let writerOccupied = "retirement IN ('pending','failed')"
    static func isRunning(_ root: Row) -> Bool {
        root["task_state"] as String == "running" && (root["pending_question_id"] as String?) == nil
    }
    static func entry(_ id: String, db: Database) throws -> Row {
        guard
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM writer_executions WHERE request_message_id=?",
                arguments: [id])
        else { throw RecordStorageError.missingRecord }
        return row
    }
    static func workspace(_ row: Row) throws -> WriterWorkspaceRecord {
        let key: Int64 = row["id"]
        var result = WriterWorkspaceRecord(
            workspaceID: "workspace_\(key)", title: row["title"],
            status: row["workspace_state"], updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
        result.workspaceReady = row["workspace_state"] as String == "ready"
        return result
    }
    public func beginRequest(
        delegateID: String, workspaceID: String?, goal: String, input: String, sourceDialog: String?, agent: String
    ) async throws -> WriterRequestRecord {
        guard agent == "writer", !goal.isEmpty else { throw RecordStorageError.invalidRecord }
        return try database.write { db in
            if try Row.fetchOne(
                db, sql: "SELECT * FROM writer_executions WHERE request_message_id=?",
                arguments: [delegateID]) != nil
            {
                return try Self.requestView(delegateID, db: db)
            }
            guard let incoming = try AgentMessageRow.fetchOne(db, key: delegateID),
                incoming.receiverAgentID == "writer", !incoming.senderAgentID.isEmpty,
                incoming.contract == "agent.task.v1",
                incoming.correlationID == delegateID, incoming.replyToID == nil, incoming.consumedAt == nil
            else { throw RecordStorageError.conflict }
            let busy =
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM writer_executions WHERE \(Self.writerOccupied)"
                ) != 0
            let key = try SQLiteRecordCoding.allocateMessage(db)
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql:
                    "INSERT INTO writer_executions(id,request_message_id,user_input_json,request_goal,task_state,retirement,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                arguments: [
                    key, delegateID,
                    try SQLiteRecordCoding.json([
                        "text": input, "source_agent": incoming.senderAgentID,
                        "source_context": incoming.senderContext as Any? ?? NSNull(),
                        "source_agent_message_id": delegateID, "original_payload": incoming.payloadJson,
                    ]), goal,
                    busy ? "failed" : "running", busy ? "none" : "pending", now, now,
                ])
            if busy {
                try db.execute(
                    sql:
                        "UPDATE writer_executions SET completed_at=?,failure_json=? WHERE id=?",
                    arguments: [
                        now,
                        try SQLiteRecordCoding.json([
                            "message": "Writer is busy with another delegation", "code": "writer.busy",
                        ]), key,
                    ])
            }
            try db.execute(
                sql:
                    "UPDATE agent_messages SET received_at=COALESCE(received_at,?),consumed_at=? WHERE id=?",
                arguments: [now, now, delegateID])
            // Explicit test/host selection uses the same immutable binding operation as native select.
            if let workspaceID, !busy {
                _ = try Self.bind(delegateID, target: BusinessRecordID.number(workspaceID, kind: .workspace), db: db)
            }
            return try Self.requestView(delegateID, db: db)
        }
    }
    static func bind(_ request: String, target: Int64, db: Database) throws -> WriterWorkspaceRecord {
        let root = try entry(request, db: db)
        guard Self.isRunning(root),
            let row = try Row.fetchOne(
                db,
                sql:
                    "SELECT * FROM writer_workspaces WHERE id=? AND workspace_state NOT IN ('deleting','deleted')",
                arguments: [target])
        else { throw RecordStorageError.conflict }
        if let selected: Int64 = root["selected_workspace_id"] {
            guard selected == target else { throw RecordStorageError.conflict }
            return try Self.workspace(row)
        }
        guard row["write_lease"] as String? == nil else { throw RecordStorageError.conflict }
        try db.execute(
            sql: "UPDATE writer_executions SET selected_workspace_id=?,request_revision=request_revision+1 WHERE id=?",
            arguments: [target, root["id"] as Int64])
        return try Self.workspace(row)
    }
    public func selectWorkspace(requestID: String, workspaceID: String) async throws -> WriterWorkspaceRecord {
        try database.write { db in
            let key = try BusinessRecordID.number(workspaceID, kind: .workspace)
            guard
                try String.fetchOne(
                    db, sql: "SELECT workspace_state FROM writer_workspaces WHERE id=?", arguments: [key]) == "ready"
            else { throw RecordStorageError.missingRecord }
            return try Self.bind(requestID, target: key, db: db)
        }
    }
    public func createWorkspace(requestID: String, title: String) async throws -> WriterWorkspaceRecord {
        try database.write { db in
            let root = try Self.entry(requestID, db: db)
            if let existing: Int64 = root["selected_workspace_id"] {
                return try Self.bind(requestID, target: existing, db: db)
            }
            guard Self.isRunning(root) else { throw RecordStorageError.conflict }
            return try Self.allocateWorkspace(title: title, root: root, db: db)
        }
    }

    public func createWorkspace(requestID: String, title: String, replacing previousWorkspaceID: String) async throws
        -> WriterWorkspaceRecord
    {
        try database.write { db in
            let root = try Self.entry(requestID, db: db)
            let previous = try BusinessRecordID.number(previousWorkspaceID, kind: .workspace)
            guard Self.isRunning(root), root["selected_workspace_id"] as Int64? == previous else {
                throw RecordStorageError.conflict
            }
            return try Self.allocateWorkspace(title: title, root: root, db: db)
        }
    }

    private static func allocateWorkspace(title: String, root: Row, db: Database) throws -> WriterWorkspaceRecord {
        let now = Date().timeIntervalSince1970
        let goal: String? = root["request_goal"]
        var row = WriterWorkspaceRow(description: goal ?? title, title: title, createdAt: now, updatedAt: now)
        try row.insert(db)
        guard let key = row.id,
            let stored = try Row.fetchOne(db, sql: "SELECT * FROM writer_workspaces WHERE id=?", arguments: [key])
        else { throw RecordStorageError.missingRecord }
        return try Self.workspace(stored)
    }

    public func switchWorkspace(requestID: String, from previousWorkspaceID: String, to workspaceID: String)
        async throws
    {
        try database.write { db in
            let root = try Self.entry(requestID, db: db)
            let previous = try BusinessRecordID.number(previousWorkspaceID, kind: .workspace)
            let target = try BusinessRecordID.number(workspaceID, kind: .workspace)
            guard previous != target, Self.isRunning(root),
                root["selected_workspace_id"] as Int64? == previous
            else { throw RecordStorageError.conflict }
            try db.execute(
                sql: """
                    UPDATE writer_workspaces SET workspace_state='ready',revision=revision+1
                    WHERE id=? AND workspace_state NOT IN ('deleting','deleted') AND write_lease IS NULL
                    """, arguments: [target])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
            try db.execute(
                sql:
                    "UPDATE writer_executions SET selected_workspace_id=?,request_revision=request_revision+1 WHERE id=?",
                arguments: [target, root["id"] as Int64])
        }
    }

    public func acceptWriterInput(_ id: String, requestID: String, questionID: String?) async throws
        -> Bool
    {
        try database.write { db in
            let root = try Self.entry(requestID, db: db)
            guard let incoming = try AgentMessageRow.fetchOne(db, key: id), incoming.receiverAgentID == "writer",
                incoming.correlationID == requestID,
                root["task_state"] as String == "running"
            else { throw RecordStorageError.conflict }
            if incoming.consumedAt != nil { return false }
            guard incoming.contract == "agent.task.v1",
                let original = try AgentMessageRow.fetchOne(db, key: requestID),
                incoming.senderAgentID == original.senderAgentID, incoming.sourceSessionID == original.sourceSessionID,
                (root["pending_question_id"] as String?) == questionID
            else {
                throw RecordStorageError.conflict
            }
            let now = Date().timeIntervalSince1970
            if questionID != nil {
                try db.execute(
                    sql: """
                        UPDATE writer_executions
                        SET pending_question_id=NULL,pending_question_json=NULL,
                            request_revision=request_revision+1,updated_at=?
                        WHERE request_message_id=?
                        """, arguments: [now, requestID])
            }
            try SQLiteAgentMessageRepository.consumeSource(id, at: now, db: db)
            return true
        }
    }
    public func acceptWriterCancellation(_ id: String, requestID: String, reason: String) async throws -> Bool {
        guard !reason.isEmpty, reason.utf8.count <= 4096 else { throw RecordStorageError.invalidRecord }
        return try database.write { db in
            guard let incoming = try AgentMessageRow.fetchOne(db, key: id),
                incoming.contract == "agent.task.v1",
                let original = try AgentMessageRow.fetchOne(db, key: requestID),
                incoming.senderAgentID == original.senderAgentID, incoming.sourceSessionID == original.sourceSessionID,
                incoming.receiverAgentID == "writer", incoming.correlationID == requestID
            else { throw RecordStorageError.conflict }
            if incoming.consumedAt != nil { return false }
            let marker = try SQLiteRecordCoding.json(["kind": "cancellation", "reason": reason])
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                    UPDATE writer_executions SET task_state='cancelling',request_revision=request_revision+1,updated_at=?,
                        runtime_results_json=json_insert(runtime_results_json,'$[#]',json(?))
                    WHERE request_message_id=? AND task_state='running'
                    """, arguments: [now, marker, requestID])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
            try SQLiteAgentMessageRepository.consumeSource(id, at: now, db: db)
            return true
        }
    }
    public func workspaces(agent: String, before: Int64?, limit: Int) async throws -> [WriterWorkspaceRecord] {
        guard agent == "writer", (1...50).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM writer_workspaces WHERE id<? AND workspace_state='ready' ORDER BY id DESC LIMIT ?",
                arguments: [before ?? Int64.max, limit]
            ).map(Self.workspace)
        }
    }
    public func workspace(_ id: String, agent: String) async throws -> WriterWorkspaceRecord {
        guard agent == "writer" else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM writer_workspaces WHERE id=?",
                    arguments: [try BusinessRecordID.number(id, kind: .workspace)])
            else { throw RecordStorageError.missingRecord }
            return try Self.workspace(row)
        }
    }
    public func prepareWorkspace(workspaceID: String, delegateID: String, agent: String, ready: Bool)
        async throws
    {
        guard agent == "writer" else { throw RecordStorageError.invalidRecord }
        try database.write { db in
            let key = try BusinessRecordID.number(workspaceID, kind: .workspace)
            _ = try Self.bind(delegateID, target: key, db: db)
            try db.execute(
                sql:
                    "UPDATE writer_workspaces SET workspace_state=CASE WHEN ? THEN 'ready' ELSE workspace_state END,revision=revision+1 WHERE id=? AND workspace_state NOT IN ('deleting','deleted')",
                arguments: [ready, key])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
        }
    }
    public func saveInteraction(delegateID: String, interactionID: String?, data: Data?) async throws {
        guard (interactionID == nil) == (data == nil) else { throw RecordStorageError.invalidRecord }
        try database.write { db in
            guard let request = try AgentMessageRow.fetchOne(db, key: delegateID) else {
                throw RecordStorageError.missingRecord
            }
            if let interactionID, let data {
                try SQLiteAgentMessageRepository.enqueue(
                    .init(
                        id: interactionID, sender: "writer", receiver: request.senderAgentID,
                        contract: "writer.question", payload: data, correlationID: request.correlationID,
                        replyTo: delegateID, senderContext: request.senderContext,
                        sourceSessionID: request.sourceSessionID, dedupeKey: interactionID), db: db)
            }
            try db.execute(
                sql:
                    "UPDATE writer_executions SET pending_question_id=?,pending_question_json=?,request_revision=request_revision+1 WHERE request_message_id=? AND task_state='running'",
                arguments: [
                    interactionID, data.map { String(decoding: $0, as: UTF8.self) },
                    delegateID,
                ])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
        }
    }
    static func recoverWriterExecutions(_ db: Database) throws {
        try db.execute(
            sql:
                "UPDATE writer_workspaces SET has_draft=1,index_needs_recovery=1,write_lease=NULL WHERE write_lease IS NOT NULL"
        )
        try db.execute(
            sql:
                "UPDATE writer_executions SET task_state='interrupted',completed_at=strftime('%s','now'),pending_question_id=NULL,pending_question_json=NULL,failure_json=?,updated_at=? WHERE task_state IN ('running','cancelling')",
            arguments: [
                "{\"message\":\"Process interrupted; external effects are never replayed\"}",
                Date().timeIntervalSince1970,
            ])
        // Execution grants do not survive the process, so an unfinished retirement has nothing left to release.
        try db.execute(
            sql: "UPDATE writer_executions SET retirement='done',updated_at=? WHERE \(Self.writerOccupied)",
            arguments: [Date().timeIntervalSince1970])
    }
}
