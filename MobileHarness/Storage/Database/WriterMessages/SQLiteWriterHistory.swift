import Foundation
internal import GRDB
import StorageChat
import StorageCore

extension SQLiteWriterMessageRepository {
    static func history(_ owner: Owner, db: Database) throws -> WriterHistoryMetadata {
        let table = owner.request ? "writer_executions" : "writer_workspaces"
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id=?", arguments: [owner.key]) else {
            throw RecordStorageError.missingRecord
        }
        return WriterHistoryMetadata(
            id: owner.id, createdAt: Date(timeIntervalSince1970: row["created_at"]), archivedAt: nil,
            title: row[owner.request ? "request_goal" : "title"], titleError: nil,
            revision: UInt64(row[owner.request ? "request_revision" : "revision"] as Int64),
            count: try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM writer_messages WHERE \(owner.column)=?", arguments: [owner.key]) ?? 0,
            latestUser: nil, traceID: SQLiteRecordKey.traceIdentity(owner.key, namespace: owner.request ? 3 : 2))
    }
    public func current() throws -> WriterHistoryMetadata {
        try database.read { db in
            guard
                let key = try Int64.fetchOne(
                    db,
                    sql:
                        "SELECT id FROM writer_executions WHERE run_state!='rejected' ORDER BY CASE WHEN run_state IN ('running','waiting_input','paused','closing','cleanup_failed') THEN 0 ELSE 1 END,id DESC LIMIT 1"
                )
            else { throw RecordStorageError.missingRecord }
            return try Self.history(Owner(key: key, request: true), db: db)
        }
    }
    public func ownerMetadata(_ id: String) throws -> WriterHistoryMetadata {
        try database.read { db in try Self.history(Self.owner(id, db: db), db: db) }
    }
}
