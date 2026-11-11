import Foundation
internal import GRDB
import StorageCore
import StorageDatabase

public final class SQLiteWorkspaceRepository: WorkspaceRepository {
    private let database: SQLiteDatabase
    internal init(database: SQLiteDatabase) { self.database = database }
    private static func number(_ id: WorkspaceID) throws -> Int64 {
        guard id.agent == "writer" else { throw RecordStorageError.invalidID }
        return try BusinessRecordID.number(id.rawValue, kind: .workspace)
    }
    private static func value(_ row: Row, db: Database, includingFiles: Bool) throws -> WorkspaceSummary {
        let record = try WriterWorkspaceRow(row: row)
        guard let key = record.id else { throw RecordStorageError.invalidRecord }
        guard let id = WorkspaceID(rawValue: "workspace_\(key)") else {
            throw RecordStorageError.invalidRecord
        }
        let raw: String? = record.workspaceToken
        let revision = raw.flatMap(UUID.init(uuidString:))
        guard raw == nil || revision != nil else { throw RecordStorageError.invalidRecord }
        let files = includingFiles ? try WorkspaceFileRow.files(db, workspaceID: key) : []
        return .init(
            id: id, title: record.title, entry: record.entry, revision: revision,
            hasDraft: record.hasDraft != 0, deleting: record.workspaceState == "deleting", files: files,
            needsIndexRecovery: record.indexNeedsRecovery != 0)
    }
    public func directory() async throws -> [WorkspaceSummary] {
        try database.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM writer_workspaces WHERE workspace_state IN ('ready','deleting') ORDER BY id"
            ).map {
                try Self.value($0, db: db, includingFiles: false)
            }
        }
    }
    public func search(_ query: String, before: String?) async throws -> (
        matches: [WorkspaceSummary], nextBefore: String?
    ) {
        let cursor = try before.map { try BusinessRecordID.number($0, kind: .workspace) } ?? Int64.max
        let pageSize = 12
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM writer_workspaces WHERE workspace_state='ready' AND id < ?
                    AND (? = '' OR instr(lower(title), lower(?)) > 0 OR instr(lower(description), lower(?)) > 0
                        OR ('workspace_' || id) = ?)
                    ORDER BY id DESC LIMIT ?
                    """,
                arguments: [cursor, query, query, query, query, pageSize + 1])
            let matches = try rows.prefix(pageSize).map { try Self.value($0, db: db, includingFiles: false) }
            return (matches, rows.count > pageSize ? matches.last?.id.rawValue : nil)
        }
    }
    public func workspace(_ id: WorkspaceID) async throws -> WorkspaceSummary? {
        try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM writer_workspaces WHERE id=? AND workspace_state='ready'",
                    arguments: [try Self.number(id)])
            else { return nil }
            guard row["write_lease"] as String? == nil else { throw RecordStorageError.busy }
            return try Self.value(row, db: db, includingFiles: true)
        }
    }
    public func claim(_ id: WorkspaceID, expecting: UUID?, lease: UUID) async throws {
        try database.write { db in
            let number = try Self.number(id)
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM writer_workspaces WHERE id=?", arguments: [number])
            else { throw RecordStorageError.missingRecord }
            guard !["deleting", "deleted"].contains(row["workspace_state"] as String),
                (row["write_lease"] as String?) == nil,
                (row["workspace_token"] as String?) == expecting?.uuidString
            else { throw RecordStorageError.conflict }
            try db.execute(
                sql:
                    "UPDATE writer_workspaces SET write_lease=?,has_draft=1,index_needs_recovery=1,workspace_state='ready',revision=revision+1 WHERE id=?",
                arguments: [lease.uuidString, row["id"] as Int64])
        }
    }
    public func commit(_ value: WorkspaceSummary, lease: UUID) async throws {
        try database.write { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT id FROM writer_workspaces WHERE id=? AND write_lease=? AND workspace_state NOT IN ('deleting','deleted')",
                    arguments: [try Self.number(value.id), lease.uuidString])
            else { throw RecordStorageError.conflict }
            let key: Int64 = row["id"]
            try WorkspaceFileRow.replace(db, workspaceID: key, files: value.files)
            try db.execute(
                sql:
                    "UPDATE writer_workspaces SET updated_at=strftime('%s','now'),title=?,entry=?,workspace_token=?,has_draft=?,index_needs_recovery=0,write_lease=NULL,revision=revision+1 WHERE id=?",
                arguments: [value.title, value.entry, value.revision?.uuidString, value.hasDraft ? 1 : 0, key])
        }
    }
    public func release(_ id: WorkspaceID, lease: UUID) async throws {
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE writer_workspaces SET write_lease=NULL,has_draft=1,index_needs_recovery=1 WHERE id=? AND write_lease=?",
                arguments: [try Self.number(id), lease.uuidString])
        }
    }
    public func markDeleting(_ id: WorkspaceID) async throws {
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE writer_workspaces SET workspace_state='deleting',revision=revision+1 WHERE id=? AND write_lease IS NULL AND NOT EXISTS(SELECT 1 FROM writer_executions m WHERE m.selected_workspace_id=writer_workspaces.id AND m.run_state IN ('running','waiting_input','paused','closing','cleanup_failed'))",
                arguments: [try Self.number(id)])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
        }
    }
    public func finishDeleting(_ id: WorkspaceID) async throws {
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE writer_workspaces SET workspace_state='deleted',deleted_at=strftime('%s','now') WHERE id=? AND workspace_state='deleting' AND write_lease IS NULL",
                arguments: [try Self.number(id)])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
            try WorkspaceFileRow.replace(db, workspaceID: Self.number(id), files: [])
        }
    }
}
