import Foundation
internal import GRDB
import StorageCore
import StorageTasks

extension SQLiteWriterExecutionRepository {
    static func completionState(_ id: String, db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT terminal_state FROM writer_executions WHERE request_message_id=?",
            arguments: [id])
    }
    static func requestStatus(_ id: String, db: Database) throws -> String? {
        guard
            let row = try Row.fetchOne(
                db,
                sql:
                    "SELECT run_state,terminal_state FROM writer_executions WHERE request_message_id=?",
                arguments: [id])
        else {
            guard let message = try AgentMessageRow.fetchOne(db, key: id),
                message.receiverAgentID == "writer",
                message.contract == "agent.task.v1",
                message.consumedAt == nil
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
        let recordedCancellation = try String.fetchOne(
            db,
            sql: """
                SELECT COALESCE(json_extract(value,'$.cancellationReason'),json_extract(value,'$.reason'))
                FROM writer_executions, json_each(runtime_results_json)
                WHERE request_message_id=?
                  AND (json_extract(value,'$.kind')='cancellation' OR json_extract(value,'$.cancellationReason') IS NOT NULL)
                ORDER BY json_each.key DESC LIMIT 1
                """, arguments: [id])
        let cancelled = recordedCancellation
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
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM writer_executions") ?? 0
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
                    "SELECT request_message_id FROM writer_executions WHERE id<? ORDER BY id DESC LIMIT ?",
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
                    "SELECT request_message_id FROM writer_executions WHERE selected_workspace_id=?",
                arguments: [try BusinessRecordID.number(id, kind: .workspace)]
            ).map { try Self.requestView($0, db: db) }.sorted { $0.createdAt < $1.createdAt }
        }
    }
    public func completeRequest(
        _ delegateID: String, eventID: String, result: Data, status: String, failure: String?,
        cancellationReason: String?
    ) async throws {
        guard ["completed", "failed", "cancelled", "interrupted"].contains(status),
            cancellationReason.map({ status == "cancelled" && !$0.isEmpty && $0.utf8.count <= 4096 }) ?? true
        else { throw RecordStorageError.invalidRecord }
        try database.write { db in
            let entry = try Self.entry(delegateID, db: db)
            let key: Int64 = entry["id"]
            guard
                ["running", "waiting_input", "paused", "closing", "interrupted"].contains(entry["run_state"] as String)
            else {
                throw RecordStorageError.conflict
            }
            var completion = [
                "kind": "completion", "state": status, "eventID": eventID, "failure": failure ?? "",
            ]
            completion["cancellationReason"] = cancellationReason
            let marker = try SQLiteRecordCoding.json(completion)
            try db.execute(
                sql:
                    "UPDATE writer_executions SET runtime_results_json=json_insert(runtime_results_json,'$[#]',json(?)),completed_at=?,updated_at=? WHERE id=?",
                arguments: [marker, Date().timeIntervalSince1970, Date().timeIntervalSince1970, key])
            try db.execute(
                sql:
                    "UPDATE writer_executions SET run_state='closing',terminal_state=?,result_json=?,pending_question_id=NULL,pending_question_json=NULL,failure_json=?,updated_at=?,request_revision=request_revision+1 WHERE id=?",
                arguments: [
                    status, String(decoding: result, as: UTF8.self),
                    try failure.map { try SQLiteRecordCoding.json(["message": $0]) },
                    Date().timeIntervalSince1970,
                    key,
                ])
        }
    }
    public func retireRequest(_ delegateID: String, failure: String?) async throws {
        try database.write { db in
            guard let state = try Self.completionState(delegateID, db: db) else {
                throw RecordStorageError.missingRecord
            }
            try db.execute(
                sql:
                    "UPDATE writer_executions SET run_state=?,failure_json=CASE WHEN ? THEN failure_json ELSE ? END,updated_at=?,request_revision=request_revision+1 WHERE request_message_id=? AND run_state IN ('closing','cleanup_failed')",
                arguments: [
                    failure == nil ? state : "cleanup_failed", failure == nil,
                    try failure.map { try SQLiteRecordCoding.json(["message": $0, "stage": "cleanup"]) },
                    Date().timeIntervalSince1970, delegateID,
                ])
        }
    }
}
