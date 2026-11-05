import Foundation
internal import GRDB
import StorageCore
import StorageTasks

public final class SQLiteTaskRepository: TaskRepository {
    public var storageScope: UUID { database.storageScope }
    private let database: SQLiteDatabase
    internal init(database: SQLiteDatabase) { self.database = database }
    internal static let schemaSQL = """
        CREATE TABLE assistant_tasks(id INTEGER PRIMARY KEY AUTOINCREMENT,dialog_id INTEGER REFERENCES assistant_conversations(id) ON DELETE CASCADE,
          agent TEXT NOT NULL,executor TEXT NOT NULL,execution TEXT NOT NULL,parent_task_id INTEGER REFERENCES assistant_tasks(id) ON DELETE SET NULL,
          goal TEXT NOT NULL,status TEXT NOT NULL,created_at REAL NOT NULL,finished_at REAL,first_position INTEGER,summary TEXT,failure TEXT,
          compression_json TEXT,source_revision INTEGER NOT NULL DEFAULT 0,summary_revision INTEGER);
        CREATE INDEX task_dialog ON assistant_tasks(dialog_id,id);
        CREATE INDEX task_active ON assistant_tasks(id) WHERE status IN ('running','finishing');
        CREATE TABLE writer_tasks(id INTEGER PRIMARY KEY AUTOINCREMENT,agent TEXT NOT NULL,number INTEGER NOT NULL,
          identity TEXT NOT NULL UNIQUE,goal TEXT NOT NULL,current_delegate_id TEXT,created_at REAL NOT NULL,updated_at REAL NOT NULL,
          history_revision INTEGER NOT NULL DEFAULT 0,phase TEXT NOT NULL DEFAULT 'starting',workspace_ready INTEGER NOT NULL DEFAULT 0,
          title TEXT NOT NULL DEFAULT '',entry TEXT NOT NULL DEFAULT 'index.html',workspace_token TEXT,
          workspace_reindex INTEGER NOT NULL DEFAULT 0,workspace_lease TEXT,workspace_dirty INTEGER NOT NULL DEFAULT 0,deleting INTEGER NOT NULL DEFAULT 0,UNIQUE(agent,number));
        CREATE TABLE agent_delegations(position INTEGER PRIMARY KEY AUTOINCREMENT,delegate_id TEXT NOT NULL UNIQUE,
          requester TEXT NOT NULL,agent TEXT NOT NULL,task_id INTEGER REFERENCES writer_tasks(id) ON DELETE CASCADE,goal TEXT NOT NULL,input TEXT NOT NULL,
          source_dialog_id INTEGER REFERENCES assistant_conversations(id) ON DELETE SET NULL,
          source_message_id INTEGER REFERENCES messages(id) ON DELETE SET NULL,status TEXT NOT NULL DEFAULT 'requested',
          created_at REAL NOT NULL,finished_at REAL,failure TEXT,cancellation_reason TEXT,
          interaction_id TEXT,interaction_payload BLOB,event_id TEXT UNIQUE,payload BLOB,delivered_at REAL,retired_at REAL,delivery_failure TEXT,retirement_failure TEXT);
        CREATE INDEX delegated_owner ON writer_tasks(agent,number DESC);
        CREATE INDEX delegation_owner ON agent_delegations(agent,task_id,position);
        CREATE INDEX delegation_delivery ON agent_delegations(agent,position) WHERE payload IS NOT NULL AND delivered_at IS NULL;
        CREATE INDEX delegation_retirement ON agent_delegations(agent,position) WHERE payload IS NOT NULL AND retired_at IS NULL;
        """
    public func createDelegation(
        id: String, requester: String, executor: String, goal: String, input: String, sourceDialog: String?
    ) async throws {
        guard UUID(uuidString: id) != nil, !requester.isEmpty, !executor.isEmpty, !goal.isEmpty else {
            throw RecordStorageError.invalidRecord
        }
        let source = try sourceDialog.map { try BusinessRecordID.number($0, kind: .dialog) }
        try database.write { db in
            if let row = try Row.fetchOne(
                db, sql: "SELECT * FROM agent_delegations WHERE delegate_id=?", arguments: [id])
            {
                guard row["requester"] as String == requester, row["agent"] as String == executor,
                    row["goal"] as String == goal, row["input"] as String == input,
                    row["source_dialog_id"] as Int64? == source
                else { throw RecordStorageError.conflict }
                return
            }
            try db.execute(
                sql:
                    "INSERT INTO agent_delegations(delegate_id,requester,agent,goal,input,source_dialog_id,created_at) VALUES(?,?,?,?,?,?,?)",
                arguments: [id, requester, executor, goal, input, source, Date().timeIntervalSince1970])
        }
    }
    public func rejectDelegation(_ id: String, failure: String) async throws {
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE agent_delegations SET status='failed',failure=?,finished_at=? WHERE delegate_id=? AND status='requested'",
                arguments: [failure, Date().timeIntervalSince1970, id])
        }
    }
    public func beginDelegation(
        delegateID: String, taskID: String?, goal: String, input: String, sourceDialog: String?, agent: String
    ) async throws -> DelegatedTaskRecord {
        guard UUID(uuidString: delegateID) != nil, !goal.isEmpty else { throw RecordStorageError.invalidRecord }
        let number = try taskID.map { try BusinessRecordID.number($0, kind: .task) }
        let stable: Int64 = try database.write { db in
            guard
                let request = try Row.fetchOne(
                    db, sql: "SELECT * FROM agent_delegations WHERE delegate_id=? AND agent=?",
                    arguments: [delegateID, agent]),
                request["goal"] as String == goal, request["input"] as String == input
            else { throw RecordStorageError.missingRecord }
            if let key = request["task_id"] as Int64? {
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM writer_tasks WHERE id=?", arguments: [key]),
                    row["current_delegate_id"] as String == delegateID,
                    number == nil || row["number"] as Int64 == number
                else { throw RecordStorageError.conflict }
                return row["number"]
            }
            guard request["status"] as String == "requested",
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM agent_delegations WHERE agent=? AND status IN ('running','finishing')",
                    arguments: [agent]) == 0
            else { throw RecordStorageError.conflict }
            let previous = try number.flatMap {
                try Row.fetchOne(
                    db, sql: "SELECT * FROM writer_tasks WHERE agent=? AND number=?", arguments: [agent, $0])
            }
            guard number == nil || previous != nil else { throw RecordStorageError.missingRecord }
            let now = Date().timeIntervalSince1970
            let key: Int64
            let allocated: Int64
            if let previous {
                key = previous["id"]
                allocated = previous["number"]
                try db.execute(
                    sql:
                        "UPDATE writer_tasks SET current_delegate_id=?,updated_at=?,phase='starting' WHERE id=? AND deleting=0",
                    arguments: [delegateID, now, key])
                guard db.changesCount == 1 else { throw RecordStorageError.conflict }
            } else {
                allocated = try Self.allocate(agent: agent, db: db)
                try db.execute(
                    sql:
                        "INSERT INTO writer_tasks(agent,number,identity,goal,current_delegate_id,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
                    arguments: [agent, allocated, UUID().uuidString, goal, delegateID, now, now])
                key = db.lastInsertedRowID
            }
            try db.execute(
                sql: "UPDATE agent_delegations SET task_id=?,status='running' WHERE delegate_id=?",
                arguments: [key, delegateID])
            return allocated
        }
        return try await delegatedTask(SQLiteRecordKey.id(.task, stable), agent: agent)
    }
    private static func task(_ row: Row) throws -> DelegatedTaskRecord {
        let agent: String = row["agent"]
        let id = SQLiteRecordKey.id(.task, row["number"])
        guard let workspace = WorkspaceID(agent: agent, taskID: id) else { throw RecordStorageError.invalidRecord }
        var value = DelegatedTaskRecord(
            id: id, dialogID: workspace.rawValue, goal: row["goal"],
            agentID: workspace.agent, delegateID: row["current_delegate_id"], status: row["status"],
            failure: row["failure"], updatedAt: Date(timeIntervalSince1970: row["latest_update"]))
        value.phase = row["phase"]
        value.workspaceReady = (row["workspace_ready"] as Int) == 1
        return value
    }
    private static let select =
        "SELECT d.*,r.status,r.failure,MAX(d.updated_at,COALESCE(r.finished_at,d.updated_at)) AS latest_update FROM writer_tasks d JOIN agent_delegations r ON r.delegate_id=d.current_delegate_id"
    public func delegatedTasks(agent: String, before: Int64?, limit: Int) async throws -> [DelegatedTaskRecord] {
        guard (1...50).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try Row.fetchAll(
                db, sql: Self.select + " WHERE d.agent=? AND d.number<? ORDER BY d.number DESC LIMIT ?",
                arguments: [agent, before ?? Int64.max, limit]
            ).map(Self.task)
        }
    }
    public func delegatedTask(_ id: String, agent: String) async throws -> DelegatedTaskRecord {
        let number = try BusinessRecordID.number(id, kind: .task)
        return try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: Self.select + " WHERE d.agent=? AND d.number=?", arguments: [agent, number])
            else { throw RecordStorageError.missingRecord }
            return try Self.task(row)
        }
    }
    private static func delegation(_ row: Row) -> DelegationRecord {
        DelegationRecord(
            taskID: SQLiteRecordKey.id(.task, row["number"]), delegateID: row["delegate_id"], goal: row["goal"],
            input: row["input"], status: row["status"], cancellationReason: row["cancellation_reason"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]), failure: row["failure"],
            finishedAt: (row["finished_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }
    public func delegationStatus(_ delegateID: String, agent: String) async throws -> String? {
        try database.read { db in
            try String.fetchOne(
                db, sql: "SELECT status FROM agent_delegations WHERE delegate_id=? AND agent=?",
                arguments: [delegateID, agent])
        }
    }
    public func delegation(_ delegateID: String, agent: String) async throws -> DelegationRecord {
        return try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT r.*,d.number FROM agent_delegations r JOIN writer_tasks d ON d.id=r.task_id WHERE r.delegate_id=? AND r.agent=?",
                    arguments: [delegateID, agent])
            else { throw RecordStorageError.missingRecord }
            return Self.delegation(row)
        }
    }
    public func delegations(_ id: String, agent: String) async throws -> [DelegationRecord] {
        let number = try BusinessRecordID.number(id, kind: .task)
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT r.*,d.number FROM agent_delegations r JOIN writer_tasks d ON d.id=r.task_id WHERE d.agent=? AND d.number=? ORDER BY r.position",
                arguments: [agent, number]
            ).map(Self.delegation)
        }
    }
    public func prepareWorkspace(_ workspace: String, taskID: String, delegateID: String, agent: String, ready: Bool)
        async throws
    {
        guard WorkspaceID(agent: agent, taskID: taskID)?.rawValue == workspace else {
            throw RecordStorageError.invalidRecord
        }
        let number = try BusinessRecordID.number(taskID, kind: .task)
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE writer_tasks SET workspace_ready=MAX(workspace_ready,?) WHERE agent=? AND number=? AND current_delegate_id=?",
                arguments: [ready ? 1 : 0, agent, number, delegateID])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
        }
    }
    public func setDelegationPhase(taskID: String, delegateID: String, phase: String, agent: String) async throws {
        guard ["starting", "running", "waitingUser", "paused", "cancelling"].contains(phase) else {
            throw RecordStorageError.invalidRecord
        }
        let number = try BusinessRecordID.number(taskID, kind: .task)
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE writer_tasks SET phase=?,updated_at=? WHERE number=? AND agent=? AND current_delegate_id=?",
                arguments: [phase, Date().timeIntervalSince1970, number, agent, delegateID])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
        }
    }
    public func saveInteraction(delegateID: String, interactionID: String?, data: Data?) async throws {
        guard (interactionID == nil) == (data == nil), interactionID.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw RecordStorageError.invalidRecord
        }
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE agent_delegations SET interaction_id=?,interaction_payload=? WHERE delegate_id=? AND status='running' AND EXISTS(SELECT 1 FROM writer_tasks t WHERE t.id=agent_delegations.task_id AND t.current_delegate_id=agent_delegations.delegate_id)",
                arguments: [interactionID, data, delegateID])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
        }
    }
    public func requestCancellation(delegateID: String, reason: String) async throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE agent_delegations SET cancellation_reason=? WHERE delegate_id=?",
                arguments: [String(reason.prefix(1024)), delegateID])
        }
    }
    public func completeDelegation(_ notification: TaskNotification, status: String, failure: String?) async throws {
        guard ["completed", "failed", "cancelled", "interrupted"].contains(status),
            UUID(uuidString: notification.eventID) != nil
        else { throw RecordStorageError.invalidRecord }
        try database.write { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM agent_delegations WHERE delegate_id=? AND agent=?",
                    arguments: [notification.delegateID, notification.agent]), row["task_id"] as Int64? != nil
            else { throw RecordStorageError.missingRecord }
            if let previous = try Row.fetchOne(
                db, sql: "SELECT event_id,payload FROM agent_delegations WHERE delegate_id=? AND payload IS NOT NULL",
                arguments: [notification.delegateID])
            {
                guard previous["event_id"] as String == notification.eventID,
                    previous["payload"] as Data == notification.data
                else { throw RecordStorageError.conflict }
                return
            }
            guard ["running", "finishing", status].contains(row["status"] as String) else {
                throw RecordStorageError.conflict
            }
            try db.execute(
                sql:
                    "UPDATE agent_delegations SET status=?,failure=?,finished_at=?,interaction_id=NULL,interaction_payload=NULL WHERE delegate_id=?",
                arguments: [status, failure, Date().timeIntervalSince1970, notification.delegateID])
            try db.execute(
                sql: "UPDATE agent_delegations SET event_id=?,payload=? WHERE delegate_id=?",
                arguments: [notification.eventID, notification.data, notification.delegateID])
        }
    }
    private static func notification(_ row: Row) -> TaskNotification {
        TaskNotification(
            delegateID: row["delegate_id"], agent: row["agent"], eventID: row["event_id"], data: row["payload"],
            delivered: row["delivered_at"] as Double? != nil, retired: row["retired_at"] as Double? != nil,
            position: row["position"])
    }
    public func taskNotification(_ delegateID: String, agent: String) async throws -> TaskNotification? {
        try database.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM agent_delegations WHERE delegate_id=? AND agent=? AND payload IS NOT NULL",
                arguments: [delegateID, agent]
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
                    "SELECT * FROM agent_delegations WHERE agent=? AND payload IS NOT NULL AND \(column) IS NULL AND position>? ORDER BY position LIMIT ?",
                arguments: [agent, after ?? 0, limit]
            ).map(Self.notification)
        }
    }
    public func finishTaskNotification(
        _ delegateID: String, agent: String, retirement: Bool, completed: Bool, failure: String?
    ) async throws {
        let column = retirement ? "retired_at" : "delivered_at"
        let errorColumn = retirement ? "retirement_failure" : "delivery_failure"
        try database.write { db in
            if completed {
                try db.execute(
                    sql:
                        "UPDATE agent_delegations SET \(column)=COALESCE(\(column),?),\(errorColumn)=? WHERE delegate_id=? AND agent=?",
                    arguments: [Date().timeIntervalSince1970, failure, delegateID, agent])
            } else {
                try db.execute(
                    sql: "UPDATE agent_delegations SET \(errorColumn)=? WHERE delegate_id=? AND agent=?",
                    arguments: [failure, delegateID, agent])
            }
        }
    }
    internal static func allocate(agent: String, db: Database) throws -> Int64 {
        let name = "agent-task:" + agent
        let next =
            (try Int64.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name=?", arguments: [name]) ?? 0) + 1
        try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name=?", arguments: [name])
        try db.execute(sql: "INSERT INTO sqlite_sequence(name,seq) VALUES(?,?)", arguments: [name, next])
        return next
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
                    "UPDATE writer_tasks SET workspace_dirty=1,workspace_reindex=1,workspace_lease=NULL WHERE workspace_lease IS NOT NULL"
            )
            try db.execute(
                sql:
                    "UPDATE assistant_tasks SET status='interrupted',failure='Interrupted; actions are never replayed',finished_at=? WHERE status IN ('running','finishing')",
                arguments: [Date().timeIntervalSince1970])
        }
    }
}

private struct SQLiteTaskRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "assistant_tasks"
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
