import Foundation
internal import GRDB
import StorageCore
import StorageDatabase

public final class SQLiteWorkspaceRepository: WorkspaceRepository {
    private let database: SQLiteDatabase
    internal init(database: SQLiteDatabase) { self.database = database }
    static let schemaSQL = """
        CREATE TABLE workspace_files(task_id INTEGER NOT NULL REFERENCES writer_tasks(id) ON DELETE CASCADE,
          path TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>=0),fingerprint TEXT NOT NULL,updated_at REAL NOT NULL,
          PRIMARY KEY(task_id,path));
        """
    private static func number(_ id: WorkspaceID) throws -> Int64 {
        try BusinessRecordID.number(id.taskID, kind: .task)
    }
    private static func value(_ row: Row, db: Database, includingFiles: Bool) throws -> WorkspaceSummary {
        guard let id = WorkspaceID(agent: row["agent"], taskID: "task_\(row["number"] as Int64)") else {
            throw RecordStorageError.invalidRecord
        }
        let raw: String? = row["workspace_token"]
        let revision = raw.flatMap(UUID.init(uuidString:))
        guard raw == nil || revision != nil else { throw RecordStorageError.invalidRecord }
        let files: [WorkspaceFile] =
            includingFiles
            ? try Row.fetchAll(
                db, sql: "SELECT path,bytes,fingerprint FROM workspace_files WHERE task_id=? ORDER BY path",
                arguments: [row["id"] as Int64]
            ).map { .init(path: $0["path"], bytes: $0["bytes"], fingerprint: $0["fingerprint"]) } : []
        return .init(
            id: id, title: row["title"], entry: row["entry"], revision: revision,
            hasDraft: (row["workspace_dirty"] as Int) != 0, deleting: (row["deleting"] as Int) != 0, files: files,
            needsIndexRecovery: (row["workspace_reindex"] as Int) != 0)
    }
    public func directory() async throws -> [WorkspaceSummary] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM writer_tasks WHERE workspace_ready=1 ORDER BY agent,number").map {
                try Self.value($0, db: db, includingFiles: false)
            }
        }
    }
    public func workspace(_ id: WorkspaceID) async throws -> WorkspaceSummary? {
        try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM writer_tasks WHERE agent=? AND number=? AND workspace_ready=1",
                    arguments: [id.agent, try Self.number(id)])
            else { return nil }
            guard row["workspace_lease"] as String? == nil else { throw RecordStorageError.busy }
            return try Self.value(row, db: db, includingFiles: true)
        }
    }
    public func claim(_ id: WorkspaceID, expecting: UUID?, lease: UUID) async throws {
        try database.write { db in
            let number = try Self.number(id)
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM writer_tasks WHERE agent=? AND number=?", arguments: [id.agent, number])
            else { throw RecordStorageError.missingRecord }
            guard (row["deleting"] as Int) == 0, (row["workspace_lease"] as String?) == nil,
                (row["workspace_token"] as String?) == expecting?.uuidString
            else { throw RecordStorageError.conflict }
            try db.execute(
                sql:
                    "UPDATE writer_tasks SET workspace_lease=?,workspace_dirty=1,workspace_reindex=1,workspace_ready=1 WHERE id=?",
                arguments: [lease.uuidString, row["id"] as Int64])
        }
    }
    public func commit(_ value: WorkspaceSummary, lease: UUID) async throws {
        try database.write { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT id FROM writer_tasks WHERE agent=? AND number=? AND workspace_lease=? AND deleting=0",
                    arguments: [value.id.agent, try Self.number(value.id), lease.uuidString])
            else { throw RecordStorageError.conflict }
            let key: Int64 = row["id"]
            try db.execute(sql: "DELETE FROM workspace_files WHERE task_id=?", arguments: [key])
            for file in value.files {
                try db.execute(
                    sql: "INSERT INTO workspace_files(task_id,path,bytes,fingerprint,updated_at) VALUES(?,?,?,?,?)",
                    arguments: [key, file.path, file.bytes, file.fingerprint, Date().timeIntervalSince1970])
            }
            try db.execute(
                sql:
                    "UPDATE writer_tasks SET title=?,entry=?,workspace_token=?,workspace_dirty=?,workspace_reindex=0,workspace_lease=NULL WHERE id=?",
                arguments: [value.title, value.entry, value.revision?.uuidString, value.hasDraft ? 1 : 0, key])
        }
    }
    public func release(_ id: WorkspaceID, lease: UUID) async throws {
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE writer_tasks SET workspace_lease=NULL,workspace_dirty=1,workspace_reindex=1 WHERE agent=? AND number=? AND workspace_lease=?",
                arguments: [id.agent, try Self.number(id), lease.uuidString])
        }
    }
    public func markDeleting(_ id: WorkspaceID) async throws {
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE writer_tasks SET deleting=1 WHERE agent=? AND number=? AND workspace_lease IS NULL AND NOT EXISTS(SELECT 1 FROM agent_delegations d WHERE d.task_id=writer_tasks.id AND d.status IN ('running','finishing'))",
                arguments: [id.agent, try Self.number(id)])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
        }
    }
    public func finishDeleting(_ id: WorkspaceID) async throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM writer_tasks WHERE agent=? AND number=? AND deleting=1 AND workspace_lease IS NULL",
                arguments: [id.agent, try Self.number(id)])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
        }
    }
}
