import Foundation
internal import GRDB
import StorageCore
import StorageTasks

public final class SQLiteListeningDialogRepository: ListeningDialogRepository {
    let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    public func appendListeningDialog(_ record: ListeningDialogRecord) async throws {
        guard UUID(uuidString: record.id) != nil, !record.sessionID.isEmpty, !record.episodeID.isEmpty,
            record.text.utf8.count <= ListeningDialogRecord.maximumTextBytes, record.latencyMS >= 0,
            record.createdAt.timeIntervalSince1970.isFinite
        else { throw RecordStorageError.invalidRecord }
        try database.write { db in
            try ListeningDialogRow(
                id: record.id, sessionID: record.sessionID, episodeID: record.episodeID, asrText: record.text,
                decision: record.decision.rawValue, reason: record.reason, modelTier: record.modelTier,
                modelID: record.modelID, latencyMS: Int64(record.latencyMS), error: record.error,
                createdAt: record.createdAt.timeIntervalSince1970
            ).insert(db)
            // Drop whole oldest episodes, never the one being written.
            while try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listening_dialogs")! > Self.maximumRecords,
                let oldest = try String.fetchOne(
                    db,
                    sql:
                        "SELECT episode_id FROM listening_dialogs WHERE episode_id<>? ORDER BY created_at,rowid LIMIT 1",
                    arguments: [record.episodeID])
            {
                try db.execute(sql: "DELETE FROM listening_dialogs WHERE episode_id=?", arguments: [oldest])
            }
        }
    }

    public func listeningDialogs(episodeID: String) async throws -> [ListeningDialogRecord] {
        try database.read { db in
            try ListeningDialogRow.fetchAll(
                db, sql: "SELECT * FROM listening_dialogs WHERE episode_id=? ORDER BY created_at,rowid",
                arguments: [episodeID]
            ).map(Self.record)
        }
    }

    public func recentListeningDialogs(limit: Int) async throws -> [ListeningDialogRecord] {
        guard (1...Self.maximumRecords).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try ListeningDialogRow.fetchAll(
                db, sql: "SELECT * FROM listening_dialogs ORDER BY created_at DESC,rowid DESC LIMIT ?",
                arguments: [limit]
            ).map(Self.record)
        }
    }

    private static func record(_ row: ListeningDialogRow) -> ListeningDialogRecord {
        .init(
            id: row.id, sessionID: row.sessionID, episodeID: row.episodeID, text: row.asrText,
            decision: .init(rawValue: row.decision) ?? .error, reason: row.reason, modelTier: row.modelTier,
            modelID: row.modelID, latencyMS: Int(row.latencyMS), error: row.error,
            createdAt: Date(timeIntervalSince1970: row.createdAt))
    }
}
