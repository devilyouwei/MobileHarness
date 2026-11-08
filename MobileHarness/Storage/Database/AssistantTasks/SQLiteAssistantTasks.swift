import Foundation
internal import GRDB
import StorageCore
import StorageTasks

extension SQLiteAssistantTaskRepository {
    public func createTask(
        dialog id: String?, agent: String, goal: String
    ) throws -> String {
        guard agent == "assistant", let id, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw RecordStorageError.invalidRecord }
        let key = try BusinessRecordID.number(id, kind: .dialog)
        return try database.write { db in
            var row = AssistantTaskRow(conversationID: key, description: goal, startedAt: Date().timeIntervalSince1970)
            try row.insert(db)
            guard let id = row.id else { throw RecordStorageError.invalidRecord }
            return "task_\(id)"
        }
    }
    public func endTask(_ id: String, status: String, failure: String? = nil, finishedAt: Date = Date()) throws {
        guard ["completed", "cancelled", "failed", "interrupted"].contains(status) else {
            throw RecordStorageError.invalidRecord
        }
        let key = try BusinessRecordID.number(id, kind: .task)
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE assistant_tasks SET state=?,end_reason=?,failure_json=?,ended_at=? WHERE id=? AND state IN ('running','finishing','closing','cleanup_failed')",
                arguments: [
                    status, failure == "superseded" ? "superseded" : status,
                    try failure.map { try SQLiteRecordCoding.json(["message": $0]) },
                    finishedAt.timeIntervalSince1970, key,
                ])
        }
    }
    static func recoverAssistantTasks(_ db: Database) throws {
        try db.execute(
            sql:
                "UPDATE assistant_tasks SET state='interrupted',end_reason='interrupted',ended_at=? WHERE state IN ('running','finishing','closing','cleanup_failed')",
            arguments: [Date().timeIntervalSince1970])
    }

}
