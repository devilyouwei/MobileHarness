import Foundation
internal import GRDB
import StorageCore
import StorageTasks

extension SQLiteWriterExecutionRepository {
    static func completionState(_ id: String, db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT terminal_state FROM writer_messages WHERE input_kind='delegation' AND request_message_id=?",
            arguments: [id])
    }
    static func requestStatus(_ id: String, db: Database) throws -> String? {
        guard
            let row = try Row.fetchOne(
                db,
                sql:
                    "SELECT run_state,terminal_state FROM writer_messages WHERE input_kind='delegation' AND request_message_id=?",
                arguments: [id])
        else {
            guard let message = try AgentMessageRow.fetchOne(db, key: id),
                message.receiverAgentID == "writer", message.contract == "task.request", message.consumedAt == nil
            else { return nil }
            return "requested"
        }
        if let terminal: String = row["terminal_state"] { return terminal }
        let state: String = row["run_state"]
        return ["waiting_input", "paused"].contains(state) ? "running" : state
    }

    public func requestStatus(_ delegateID: String, agent: String) async throws -> String? {
        guard agent == "writer" else { throw RecordStorageError.invalidRecord }
        return try database.read { try Self.requestStatus(delegateID, db: $0) }
    }
    static func requestView(_ id: String, db: Database) throws -> WriterRequestRecord {
        guard let request = try AgentMessageRow.fetchOne(db, key: id) else { throw RecordStorageError.missingRecord }
        let entry = try Self.entry(id, db: db)
        let original = try SQLiteRecordCoding.object(entry["user_input_json"])
        guard let input = original["text"] as? String, let sourceAgent = original["source_agent"] as? String else {
            throw RecordStorageError.invalidRecord
        }
        let goal: String = entry["request_goal"]
        let status = try requestStatus(id, db: db) ?? "interrupted"
        let cancellationPayload = try String.fetchOne(
            db,
            sql:
                "SELECT payload_json FROM agent_messages WHERE correlation_id=? AND contract='task.cancel' ORDER BY created_at DESC LIMIT 1",
            arguments: [request.correlationID])
        let cancelled = try cancellationPayload.flatMap { raw -> String? in
            let envelope = try SQLiteRecordCoding.object(raw)
            if let encoded = envelope["data"] as? String, let data = Data(base64Encoded: encoded) {
                return try SQLiteRecordCoding.payload(data)["text"] as? String
            }
            return envelope["text"] as? String
        }
        let failure: String? = entry["failure_json"]
        let finished = (entry["completed_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
        var value = WriterRequestRecord(
            workspaceID: (entry["selected_workspace_id"] as Int64?).map { "workspace_\($0)" } ?? "", delegateID: id,
            goal: goal,
            input: input,
            status: status, cancellationReason: cancelled, createdAt: Date(timeIntervalSince1970: entry["created_at"]),
            failure: failure,
            finishedAt: ["completed", "failed", "cancelled", "interrupted"].contains(status)
                ? finished : nil)
        value.messageID = UInt64(entry["id"] as Int64)
        value.sourceAgent = sourceAgent
        value.sourceContext = original["source_context"] as? String
        value.result = entry["result_json"]
        value.executionState = entry["run_state"]
        value.waiting = entry["pending_question_json"]
        return value
    }
    public func delegationCount() async throws -> Int {
        try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM writer_messages WHERE input_kind='delegation'") ?? 0
        }
    }
    public func delegations(before: UInt64?, limit: Int) async throws -> [WriterRequestRecord] {
        guard (1...50).contains(limit), before.map({ $0 <= Int64.max }) ?? true else {
            throw RecordStorageError.invalidRecord
        }
        return try database.read { db in
            try String.fetchAll(
                db,
                sql:
                    "SELECT request_message_id FROM writer_messages WHERE input_kind='delegation' AND id<? ORDER BY id DESC LIMIT ?",
                arguments: [before.map(Int64.init) ?? Int64.max, limit]
            ).map { try Self.requestView($0, db: db) }
        }
    }
    public func request(_ delegateID: String, agent: String) async throws -> WriterRequestRecord {
        guard agent == "writer" else { throw RecordStorageError.invalidRecord }
        return try database.read { try Self.requestView(delegateID, db: $0) }
    }
    public func requests(_ id: String, agent: String) async throws -> [WriterRequestRecord] {
        guard agent == "writer" else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try String.fetchAll(
                db,
                sql:
                    "SELECT request_message_id FROM writer_messages WHERE input_kind='delegation' AND selected_workspace_id=?",
                arguments: [try BusinessRecordID.number(id, kind: .workspace)]
            ).map { try Self.requestView($0, db: db) }.sorted { $0.createdAt < $1.createdAt }
        }
    }
    public func completeRequest(_ notification: WriterDelegationNotification, status: String, failure: String?)
        async throws
    {
        guard notification.agent == "writer", ["completed", "failed", "cancelled", "interrupted"].contains(status)
        else { throw RecordStorageError.invalidRecord }
        try database.write { db in
            guard let incoming = try AgentMessageRow.fetchOne(db, key: notification.delegateID) else {
                throw RecordStorageError.missingRecord
            }
            let entry = try Self.entry(notification.delegateID, db: db)
            let key: Int64 = entry["id"]
            let value = AgentCommunicationRecord(
                id: notification.eventID, sender: "writer", receiver: incoming.senderAgentID,
                contract: "writer.completion", payload: notification.data, correlationID: incoming.correlationID,
                replyTo: incoming.id, senderContext: incoming.senderContext, dedupeKey: incoming.id + ":completion")
            if try AgentMessageRow.fetchOne(db, key: notification.eventID) != nil {
                try SQLiteAgentMessageRepository.enqueue(value, db: db)
                return
            }
            guard
                ["running", "waiting_input", "paused", "closing", "interrupted"].contains(entry["run_state"] as String)
            else {
                throw RecordStorageError.conflict
            }
            let marker = try SQLiteRecordCoding.json([
                "kind": "completion", "state": status, "eventID": notification.eventID, "failure": failure ?? "",
            ])
            try db.execute(
                sql:
                    "UPDATE writer_messages SET runtime_results_json=json_insert(runtime_results_json,'$[#]',json(?)),completed_at=?,updated_at=? WHERE id=?",
                arguments: [marker, Date().timeIntervalSince1970, Date().timeIntervalSince1970, key])
            try db.execute(
                sql:
                    "UPDATE writer_messages SET run_state='closing',terminal_state=?,result_json=?,pending_question_id=NULL,pending_question_json=NULL,failure_json=?,updated_at=?,request_revision=request_revision+1 WHERE id=?",
                arguments: [
                    status, String(decoding: notification.data, as: UTF8.self),
                    try failure.map { try SQLiteRecordCoding.json(["message": $0]) },
                    Date().timeIntervalSince1970,
                    key,
                ])
            try SQLiteAgentMessageRepository.enqueue(value, db: db)
        }
    }
    static func notification(_ row: Row, db: Database) throws -> WriterDelegationNotification {
        let request: String = row["correlation_id"]
        let state = try String.fetchOne(
            db, sql: "SELECT run_state FROM writer_messages WHERE input_kind='delegation' AND request_message_id=?",
            arguments: [request])
        return WriterDelegationNotification(
            delegateID: request, agent: "writer", eventID: row["id"], data: Data((row["payload_json"] as String).utf8),
            delivered: row["delivery_state"] as String == "received",
            retired: state == nil || !["closing", "cleanup_failed"].contains(state ?? ""), position: row["position"],
            claimToken: row["claim_token"])
    }
    public func delegationNotification(_ delegateID: String, agent: String) async throws
        -> WriterDelegationNotification?
    {
        guard agent == "writer" else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try Row.fetchOne(
                db,
                sql:
                    "SELECT rowid AS position,* FROM agent_messages WHERE correlation_id=? AND sender_agent_id='writer' AND contract='writer.completion'",
                arguments: [delegateID]
            ).map { try Self.notification($0, db: db) }
        }
    }
    public func pendingDelegationNotifications(agent: String, retirement: Bool, after: Int64?, limit: Int) async throws
        -> [WriterDelegationNotification]
    {
        guard agent == "writer", (1...32).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql:
                    "UPDATE agent_messages SET delivery_state='dead_letter',last_error=COALESCE(last_error,'Delivery claim expired after final attempt'),claim_token=NULL,claim_expires_at=NULL WHERE delivery_state='in_flight' AND claim_expires_at<=? AND attempt_count>=8",
                arguments: [now])
            let filter =
                retirement
                ? "EXISTS(SELECT 1 FROM writer_messages t WHERE t.input_kind='delegation' AND t.request_message_id=m.correlation_id AND t.run_state IN ('closing','cleanup_failed'))"
                : "m.attempt_count<8 AND ((m.delivery_state='pending' AND COALESCE(m.next_attempt_at,0)<=?) OR (m.delivery_state='in_flight' AND m.claim_expires_at<=?))"
            var args: StatementArguments = [after ?? 0]
            if !retirement { args += [now, now] }
            args += [limit]
            let rows = try Row.fetchAll(
                db,
                sql:
                    "SELECT m.rowid AS position,m.* FROM agent_messages m WHERE m.sender_agent_id='writer' AND m.contract='writer.completion' AND m.rowid>? AND \(filter) ORDER BY m.rowid LIMIT ?",
                arguments: args)
            var results: [WriterDelegationNotification] = []
            for row in rows {
                if !retirement {
                    try db.execute(
                        sql:
                            "UPDATE agent_messages SET delivery_state='in_flight',claim_token=?,claim_expires_at=?,attempt_count=attempt_count+1 WHERE id=?",
                        arguments: [UUID().uuidString, now + 60, row["id"] as String])
                }
                guard
                    let current = try Row.fetchOne(
                        db, sql: "SELECT rowid AS position,* FROM agent_messages WHERE id=?",
                        arguments: [row["id"] as String])
                else { throw RecordStorageError.missingRecord }
                results.append(try Self.notification(current, db: db))
            }
            return results
        }
    }
    public func finishDelegationNotification(
        _ delegateID: String, agent: String, retirement: Bool, completed: Bool, failure: String?,
        claimToken: String? = nil
    ) async throws {
        guard agent == "writer" else { throw RecordStorageError.invalidRecord }
        try database.write { db in
            if retirement {
                guard let state = try Self.completionState(delegateID, db: db) else {
                    throw RecordStorageError.missingRecord
                }
                try db.execute(
                    sql:
                        "UPDATE writer_messages SET run_state=?,failure_json=CASE WHEN ? THEN failure_json ELSE ? END,updated_at=?,request_revision=request_revision+1 WHERE input_kind='delegation' AND request_message_id=? AND run_state IN ('closing','cleanup_failed')",
                    arguments: [
                        completed ? state : "cleanup_failed", completed,
                        try failure.map { try SQLiteRecordCoding.json(["message": $0, "stage": "cleanup"]) },
                        Date().timeIntervalSince1970, delegateID,
                    ])
                return
            }
            guard let claimToken,
                let row = try AgentMessageRow.fetchOne(
                    db,
                    sql:
                        "SELECT * FROM agent_messages WHERE correlation_id=? AND contract='writer.completion' AND claim_token=? AND delivery_state IN ('in_flight','received')",
                    arguments: [delegateID, claimToken])
            else { throw RecordStorageError.conflict }
            let now = Date().timeIntervalSince1970
            let delays: [Double] = [1, 2, 4, 8, 16, 32, 60, 60]
            let state = completed ? "received" : row.attemptCount >= 8 ? "dead_letter" : "pending"
            try db.execute(
                sql:
                    "UPDATE agent_messages SET delivery_state=?,received_at=CASE WHEN ? THEN ? ELSE received_at END,next_attempt_at=?,last_error=?,claim_token=NULL,claim_expires_at=NULL WHERE id=? AND claim_token=?",
                arguments: [
                    state, completed, now, completed ? nil : now + delays[max(0, Int(row.attemptCount) - 1)], failure,
                    row.id, claimToken,
                ])
        }
    }
}
