import Foundation
internal import GRDB
import StorageCore
import StorageMedia

public final class SQLiteMediaRepository: MediaRepository {
    private let database: SQLiteDatabase
    internal init(database: SQLiteDatabase) { self.database = database }
    internal static let schemaSQL = """
        CREATE TABLE media_files(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, mime TEXT NOT NULL,
                                relative_path TEXT NOT NULL UNIQUE, bytes INTEGER NOT NULL, source TEXT NOT NULL,
                                session_id TEXT NOT NULL, input_id TEXT NOT NULL, created_at REAL NOT NULL, captured_at REAL,
                                state TEXT NOT NULL, failure TEXT);
        CREATE INDEX media_owner ON media_files(source,input_id,id);
        CREATE INDEX media_retention ON media_files(state,created_at,id);
        """
    public func reserveMedia(bytes: Int, source: String, session: String, input: String, date: Date) throws
        -> MediaFileRecord
    {
        try database.write { db in
            try db.execute(
                sql:
                    "INSERT INTO media_files(kind,mime,relative_path,bytes,source,session_id,input_id,created_at,captured_at,state) VALUES('image','image/jpeg',?,?,?,?,?,?,?,'pending')",
                arguments: [
                    UUID().uuidString, bytes, source, session, input, Date().timeIntervalSince1970,
                    date.timeIntervalSince1970,
                ])
            let key = db.lastInsertedRowID
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(secondsFromGMT: 0)
            format.dateFormat = "yyyyMMdd_HHmmss"
            let path = "\(format.string(from:date))_\(key).jpg"
            try db.execute(sql: "UPDATE media_files SET relative_path=? WHERE id=?", arguments: [path, key])
            return MediaFileRecord(
                id: SQLiteRecordKey.id(.media, key), path: path, bytes: bytes, source: source, session: session,
                input: input,
                state: "pending")
        }
    }
    public func media(_ id: String) throws -> MediaFileRecord? {
        let key = try BusinessRecordID.number(id, kind: .media)
        return try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM media_files WHERE id=?", arguments: [key]) else {
                return nil
            }
            return Self.media(row)
        }
    }
    public func retainedMedia() throws -> [MediaFileRecord] {
        try database.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM media_files WHERE state IN ('pending','ready') ORDER BY created_at,id"
            ).map(Self.media)
        }
    }
    public func setMedia(_ id: String, state: String, failure: String? = nil) throws {
        let key = try BusinessRecordID.number(id, kind: .media)
        try database.write { db in
            try db.execute(
                sql: "UPDATE media_files SET state=?,failure=? WHERE id=?", arguments: [state, failure, key])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
        }
    }
    private static func media(_ row: Row) -> MediaFileRecord {
        MediaFileRecord(
            id: SQLiteRecordKey.id(.media, row["id"]), path: row["relative_path"], bytes: row["bytes"],
            source: row["source"], session: row["session_id"], input: row["input_id"], state: row["state"])
    }
}
