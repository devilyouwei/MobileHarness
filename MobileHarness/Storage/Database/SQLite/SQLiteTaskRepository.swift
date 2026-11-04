import Foundation
internal import GRDB
import StorageCore
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
        CREATE INDEX task_active ON tasks(id) WHERE status IN ('running','finishing');
        CREATE TABLE delegated_tasks(id INTEGER PRIMARY KEY REFERENCES tasks(id),agent TEXT NOT NULL,
          dialog_id INTEGER NOT NULL REFERENCES dialogs(id),goal TEXT NOT NULL,project_id TEXT,
          current_run_id INTEGER NOT NULL REFERENCES tasks(id),updated_at REAL NOT NULL,phase TEXT NOT NULL DEFAULT 'starting',workspace_ready INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE delegated_runs(run_id INTEGER PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
          task_id INTEGER NOT NULL REFERENCES delegated_tasks(id),input TEXT NOT NULL,
          source_dialog_id INTEGER REFERENCES dialogs(id) ON DELETE SET NULL,cancellation_reason TEXT);
        CREATE INDEX delegated_owner ON delegated_tasks(agent,id DESC);
        """
    static func prepareNotifications(_ database: SQLiteDatabase) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS task_notifications(
                      run_id INTEGER PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
                      agent TEXT NOT NULL,event_id TEXT NOT NULL UNIQUE,payload BLOB NOT NULL,
                      delivered_at REAL,retired_at REAL,delivery_failure TEXT,retirement_failure TEXT);
                    CREATE INDEX IF NOT EXISTS task_notification_delivery ON task_notifications(agent,run_id) WHERE delivered_at IS NULL;
                    CREATE INDEX IF NOT EXISTS task_notification_retirement ON task_notifications(agent,run_id) WHERE retired_at IS NULL;
                    """)
        }
    }
    public func delegatedRun(_ runID: String, agent: String) async throws -> DelegatedRunRecord {
        let key = try BusinessRecordID.number(runID, kind: .task)
        return try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT r.*,t.goal,t.status,t.created_at,t.failure FROM delegated_runs r
                        JOIN tasks t ON t.id=r.run_id JOIN delegated_tasks d ON d.id=r.task_id
                        WHERE r.run_id=? AND d.agent=?
                        """, arguments: [key, agent])
            else { throw RecordStorageError.missingRecord }
            return DelegatedRunRecord(
                taskID: SQLiteRecordKey.id(.task, row["task_id"]), runID: runID, goal: row["goal"], input: row["input"],
                status: row["status"], cancellationReason: row["cancellation_reason"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]), failure: row["failure"])
        }
    }
    public func completeDelegatedRun(_ notification: TaskNotification, status: String, failure: String?) async throws {
        let key = try BusinessRecordID.number(notification.runID, kind: .task)
        guard ["completed", "failed", "cancelled", "interrupted"].contains(status),
            UUID(uuidString: notification.eventID) != nil, notification.data.count <= 131072
        else {
            throw RecordStorageError.invalidRecord
        }
        try database.write { db in
            guard
                let owner = try String.fetchOne(
                    db,
                    sql: """
                        SELECT d.agent FROM delegated_runs r JOIN delegated_tasks d ON d.id=r.task_id WHERE r.run_id=?
                        """, arguments: [key]), owner == notification.agent,
                var row = try SQLiteTaskRow.fetchOne(db, key: key)
            else { throw RecordStorageError.missingRecord }
            if let previous = try Row.fetchOne(
                db, sql: "SELECT event_id,payload FROM task_notifications WHERE run_id=?", arguments: [key])
            {
                guard previous["event_id"] as String == notification.eventID,
                    previous["payload"] as Data == notification.data
                else { throw RecordStorageError.conflict }
                return
            }
            guard ["running", "finishing", status].contains(row.status) else { throw RecordStorageError.conflict }
            row.status = status
            row.failure = failure
            row.finishedAt = Date().timeIntervalSince1970
            try row.update(db, columns: ["status", "failure", "finished_at"])
            try db.execute(
                sql: "INSERT INTO task_notifications(run_id,agent,event_id,payload) VALUES(?,?,?,?)",
                arguments: [key, notification.agent, notification.eventID, notification.data])
        }
    }
    private static func notification(_ row: Row) -> TaskNotification {
        TaskNotification(
            runID: SQLiteRecordKey.id(.task, row["run_id"]), agent: row["agent"],
            eventID: row["event_id"], data: row["payload"], delivered: row["delivered_at"] as Double? != nil,
            retired: row["retired_at"] as Double? != nil)
    }
    public func taskNotification(_ runID: String, agent: String) async throws -> TaskNotification? {
        let key = try BusinessRecordID.number(runID, kind: .task)
        return try database.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM task_notifications WHERE run_id=? AND agent=?", arguments: [key, agent]
            ).map(Self.notification)
        }
    }
    public func pendingTaskNotifications(agent: String, retirement: Bool, after: Int64?, limit: Int) async throws
        -> [TaskNotification]
    {
        guard (1...32).contains(limit) else { throw RecordStorageError.invalidRecord }
        let column = retirement ? "retired_at" : "delivered_at"
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM task_notifications WHERE agent=? AND \(column) IS NULL AND run_id>? ORDER BY run_id LIMIT ?",
                arguments: [agent, after ?? 0, limit]
            ).map(Self.notification)
        }
    }
    public func finishTaskNotification(
        _ runID: String, agent: String, retirement: Bool, completed: Bool, failure: String?
    ) async throws {
        let key = try BusinessRecordID.number(runID, kind: .task)
        let column = retirement ? "retired_at" : "delivered_at"
        let errorColumn = retirement ? "retirement_failure" : "delivery_failure"
        try database.write { db in
            if completed {
                try db.execute(
                    sql:
                        "UPDATE task_notifications SET \(column)=COALESCE(\(column),?),\(errorColumn)=? WHERE run_id=? AND agent=?",
                    arguments: [Date().timeIntervalSince1970, failure.map { String($0.prefix(1024)) }, key, agent])
            } else {
                try db.execute(
                    sql: "UPDATE task_notifications SET \(errorColumn)=? WHERE run_id=? AND agent=?",
                    arguments: [failure.map { String($0.prefix(1024)) }, key, agent])
            }
        }
    }
    private static func delegated(_ row: Row) -> DelegatedTaskRecord {
        var value = DelegatedTaskRecord(
            id: SQLiteRecordKey.id(.task, row["id"]), dialogID: SQLiteRecordKey.id(.dialog, row["dialog_id"]),
            goal: row["goal"], projectID: row["project_id"], runID: SQLiteRecordKey.id(.task, row["current_run_id"]),
            status: row["status"], failure: row["failure"], updatedAt: Date(timeIntervalSince1970: row["latest_update"])
        )
        value.phase = row["phase"]
        value.workspaceReady = (row["workspace_ready"] as Int) == 1
        return value
    }
    private static let delegatedSelect =
        "SELECT d.*,t.status,t.failure,MAX(d.updated_at,COALESCE(t.finished_at,d.updated_at)) AS latest_update FROM delegated_tasks d JOIN tasks t ON t.id=d.current_run_id"
    public func delegatedTasks(agent: String, before: Int64?, limit: Int) async throws -> [DelegatedTaskRecord] {
        guard (1...50).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try Row.fetchAll(
                db, sql: Self.delegatedSelect + " WHERE d.agent=? AND d.id<? ORDER BY d.id DESC LIMIT ?",
                arguments: [agent, before ?? Int64.max, limit]
            ).map(Self.delegated)
        }
    }
    public func delegatedTask(_ id: String, agent: String) async throws -> DelegatedTaskRecord {
        let key = try BusinessRecordID.number(id, kind: .task)
        return try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: Self.delegatedSelect + " WHERE d.id=? AND d.agent=?", arguments: [key, agent])
            else { throw RecordStorageError.missingRecord }
            return Self.delegated(row)
        }
    }
    public func delegatedRuns(_ id: String, agent: String) async throws -> [DelegatedRunRecord] {
        _ = try await delegatedTask(id, agent: agent)
        let key = try BusinessRecordID.number(id, kind: .task)
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT r.*,t.goal,t.status,t.created_at,t.failure FROM delegated_runs r JOIN tasks t ON t.id=r.run_id WHERE r.task_id=? ORDER BY r.run_id",
                arguments: [key]
            ).map { row in
                DelegatedRunRecord(
                    taskID: id, runID: SQLiteRecordKey.id(.task, row["run_id"]), goal: row["goal"], input: row["input"],
                    status: row["status"], cancellationReason: row["cancellation_reason"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]), failure: row["failure"])
            }
        }
    }
    public func beginDelegation(taskID: String?, goal: String, input: String, sourceDialog: String?, agent: String)
        async throws -> DelegatedTaskRecord
    {
        guard !agent.isEmpty, agent.utf8.count <= 64, !goal.isEmpty, goal.utf8.count <= 1024, input.utf8.count <= 12000
        else {
            throw RecordStorageError.invalidRecord
        }
        let key = try taskID.map { try BusinessRecordID.number($0, kind: .task) }
        let source = try sourceDialog.map { try BusinessRecordID.number($0, kind: .dialog) }
        let stable: Int64 = try database.write { db in
            guard
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM delegated_tasks d JOIN tasks t ON t.id=d.current_run_id WHERE d.agent=? AND t.status IN ('running','finishing')",
                    arguments: [agent]) == 0
            else { throw RecordStorageError.conflict }
            let previous = try key.flatMap {
                try Row.fetchOne(
                    db, sql: "SELECT * FROM delegated_tasks WHERE id=? AND agent=?", arguments: [$0, agent])
            }
            guard key == nil || previous != nil else {
                throw RecordStorageError.missingRecord
            }
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: "UPDATE dialogs SET archived_at=? WHERE agent=? AND archived_at IS NULL", arguments: [now, agent])
            let dialog: Int64
            if let previous {
                dialog = previous["dialog_id"]
                try db.execute(
                    sql: "UPDATE dialogs SET archived_at=NULL WHERE id=? AND agent=?", arguments: [dialog, agent])
            } else {
                try db.execute(
                    sql: "INSERT INTO dialogs(agent,created_at,title) VALUES(?,?,?)", arguments: [agent, now, goal])
                dialog = db.lastInsertedRowID
            }
            try db.execute(
                sql:
                    "INSERT INTO tasks(dialog_id,agent,executor,execution,goal,status,created_at) VALUES(?,?,?,'background',?,'running',?)",
                arguments: [dialog, agent, agent, goal, now])
            let run = db.lastInsertedRowID
            let stable = key ?? run
            if previous == nil {
                try db.execute(
                    sql:
                        "INSERT INTO delegated_tasks(id,agent,dialog_id,goal,current_run_id,updated_at) VALUES(?,?,?,?,?,?)",
                    arguments: [stable, agent, dialog, goal, run, now])
            } else {
                try db.execute(
                    sql: "UPDATE delegated_tasks SET current_run_id=?,updated_at=?,phase='starting' WHERE id=?",
                    arguments: [run, now, stable])
            }
            try db.execute(
                sql: "INSERT INTO delegated_runs(run_id,task_id,input,source_dialog_id) VALUES(?,?,?,?)",
                arguments: [run, stable, input, source])
            return stable
        }
        return try await delegatedTask(SQLiteRecordKey.id(.task, stable), agent: agent)
    }
    public func bindProject(_ project: String, taskID: String, runID: String, agent: String, ready: Bool) async throws {
        guard UUID(uuidString: project) != nil else { throw RecordStorageError.invalidRecord }
        let task = try BusinessRecordID.number(taskID, kind: .task)
        let run = try BusinessRecordID.number(runID, kind: .task)
        try database.write { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT project_id,current_run_id FROM delegated_tasks WHERE id=? AND agent=?",
                    arguments: [task, agent]), (row["current_run_id"] as Int64) == run,
                (row["project_id"] as String?).map({ $0 == project }) ?? true
            else { throw RecordStorageError.conflict }
            try db.execute(
                sql: "UPDATE delegated_tasks SET project_id=?,workspace_ready=MAX(workspace_ready,?) WHERE id=?",
                arguments: [project, ready ? 1 : 0, task])
        }
    }
    public func setDelegationPhase(taskID: String, runID: String, phase: String, agent: String) async throws {
        guard ["starting", "running", "waitingUser", "paused", "cancelling"].contains(phase) else {
            throw RecordStorageError.invalidRecord
        }
        let key = try BusinessRecordID.number(taskID, kind: .task)
        let run = try BusinessRecordID.number(runID, kind: .task)
        try database.write { db in
            guard
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM delegated_tasks WHERE id=? AND current_run_id=? AND agent=?",
                    arguments: [key, run, agent]) == 1
            else { throw RecordStorageError.conflict }
            try db.execute(
                sql: "UPDATE delegated_tasks SET phase=?,updated_at=? WHERE id=?",
                arguments: [phase, Date().timeIntervalSince1970, key])
        }
    }
    public func requestCancellation(runID: String, reason: String) async throws {
        let run = try BusinessRecordID.number(runID, kind: .task)
        try database.write { db in
            try db.execute(
                sql: "UPDATE delegated_runs SET cancellation_reason=? WHERE run_id=?",
                arguments: [String(reason.prefix(1024)), run])
        }
    }
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
