import Foundation
internal import GRDB
import Storage
import StorageTasks

public final class SQLiteTaskRepository: TaskRepository {
    public var storageScope: UUID { database.storageScope }
    private let database: SQLiteDatabase
    internal init(database: SQLiteDatabase) { self.database = database }
    internal static let schemaSQL = """
        CREATE TABLE tasks(id INTEGER PRIMARY KEY AUTOINCREMENT, dialog_id INTEGER REFERENCES dialogs(id) ON DELETE CASCADE,
                                agent TEXT NOT NULL, executor TEXT NOT NULL, execution TEXT NOT NULL, parent_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL, goal TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL,
                                finished_at REAL, first_position INTEGER, summary TEXT, failure TEXT, compression_hash TEXT REFERENCES evidence(hash));
        CREATE INDEX task_dialog ON tasks(dialog_id,id);
        CREATE INDEX task_compression ON tasks(compression_hash);
        """
    public func createTask(
        dialog id: String?, agent: String, goal: String, executor: String? = nil, execution: String = "foreground",
        parent: String? = nil
    ) throws -> String {
        let key = try id.map { try BusinessRecordID.number($0, kind: .dialog) }
        let parentKey = try parent.map { try BusinessRecordID.number($0, kind: .task) }
        return try database.write { db in
            var row = SQLiteTaskRow(
                dialogID: key, agent: agent, executor: executor ?? agent, execution: execution,
                parentTaskID: parentKey, goal: goal, status: "running", createdAt: Date().timeIntervalSince1970)
            try row.insert(db)
            guard let id = row.id else { throw RecordStorageError.invalidRecord }
            return SQLiteRecordKey.id(.task, id)
        }
    }
    public func endTask(_ id: String, status: String, failure: String? = nil, finishedAt: Date = Date()) throws {
        let key = try BusinessRecordID.number(id, kind: .task)
        try database.write { db in
            guard var row = try SQLiteTaskRow.fetchOne(db, key: key),
                ["running", "finishing"].contains(row.status)
            else { return }
            row.status = status
            row.failure = failure
            row.finishedAt = finishedAt.timeIntervalSince1970
            try row.update(db, columns: ["status", "failure", "finished_at"])
        }
    }
    internal func recoverInFlight() throws {
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE tasks SET status='interrupted',failure='Interrupted; actions are never replayed',finished_at=? WHERE status IN ('running','finishing')",
                arguments: [Date().timeIntervalSince1970])
        }
    }
}

private struct SQLiteTaskRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "tasks"
    var id: Int64?
    var dialogID: Int64?
    var agent: String
    var executor: String
    var execution: String
    var parentTaskID: Int64?
    var goal: String
    var status: String
    var createdAt: Double
    var finishedAt: Double?
    var failure: String?
    enum CodingKeys: String, CodingKey {
        case id, agent, executor, execution, goal, status, failure
        case dialogID = "dialog_id"
        case parentTaskID = "parent_task_id"
        case createdAt = "created_at"
        case finishedAt = "finished_at"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
