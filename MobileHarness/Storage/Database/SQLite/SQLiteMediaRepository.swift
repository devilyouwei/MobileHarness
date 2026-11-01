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
    internal static let albumMigrationSQL = """
        ALTER TABLE media_files ADD COLUMN album_added_at REAL;
        ALTER TABLE media_files ADD COLUMN photo_width INTEGER;
        ALTER TABLE media_files ADD COLUMN photo_height INTEGER;
        ALTER TABLE media_files ADD COLUMN photo_origin TEXT;
        CREATE INDEX album_order ON media_files(COALESCE(captured_at,created_at) DESC,id DESC)
          WHERE album_added_at IS NOT NULL AND state='ready';
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
    public func reserveVideo(bytes: Int, owner: StorageOwner, metadata: PhotoMetadata, createdAt: Date) throws
        -> MediaFileRecord
    {
        try metadata.validate()
        guard metadata.mime == "video/quicktime", bytes > 0, bytes <= 512 * 1024 * 1024 else {
            throw RecordStorageError.invalidRecord
        }
        return try database.write { db in
            let path = UUID().uuidString + ".mov"
            try db.execute(
                sql:
                    "INSERT INTO media_files(kind,mime,relative_path,bytes,source,session_id,input_id,created_at,captured_at,state,photo_width,photo_height,photo_origin) VALUES('video',?,?,?,?,?,?,?,?,'pending',?,?,?)",
                arguments: [
                    metadata.mime, path, bytes, owner.source, owner.session, owner.input,
                    createdAt.timeIntervalSince1970,
                    metadata.capturedAt?.timeIntervalSince1970, metadata.width, metadata.height, metadata.origin,
                ])
            return MediaFileRecord(
                id: SQLiteRecordKey.id(.media, db.lastInsertedRowID), path: path, bytes: bytes,
                source: owner.source, session: owner.session, input: owner.input, state: "pending")
        }
    }
    public func reservePhoto(bytes: Int, owner: StorageOwner, metadata: PhotoMetadata, createdAt: Date) throws
        -> MediaFileRecord
    {
        try metadata.validate()
        guard metadata.mime != "video/quicktime" else { throw RecordStorageError.invalidRecord }
        return try database.write { db in
            let path = UUID().uuidString + "." + metadata.fileExtension
            try db.execute(
                sql:
                    "INSERT INTO media_files(kind,mime,relative_path,bytes,source,session_id,input_id,created_at,captured_at,state,photo_width,photo_height,photo_origin,album_added_at) VALUES('image',?,?,?,?,?,?,?,?,'pending',?,?,?,?)",
                arguments: [
                    metadata.mime, path, bytes, owner.source, owner.session, owner.input,
                    createdAt.timeIntervalSince1970, metadata.capturedAt?.timeIntervalSince1970, metadata.width,
                    metadata.height, metadata.origin, createdAt.timeIntervalSince1970,
                ])
            return MediaFileRecord(
                id: SQLiteRecordKey.id(.media, db.lastInsertedRowID), path: path, bytes: bytes, source: owner.source,
                session: owner.session, input: owner.input, state: "pending")
        }
    }
    public func collectPhoto(_ id: String, metadata: PhotoMetadata?, at date: Date) throws {
        if let metadata { try metadata.validate() }
        let key = try BusinessRecordID.number(id, kind: .media)
        try database.write { db in
            if let metadata {
                try db.execute(
                    sql:
                        "UPDATE media_files SET album_added_at=COALESCE(album_added_at,?),photo_width=?,photo_height=?,photo_origin=?,mime=? WHERE id=? AND state='ready'",
                    arguments: [
                        date.timeIntervalSince1970, metadata.width, metadata.height, metadata.origin, metadata.mime,
                        key,
                    ])
            } else {
                try db.execute(
                    sql:
                        "UPDATE media_files SET album_added_at=COALESCE(album_added_at,?) WHERE id=? AND state='ready' AND photo_width IS NOT NULL",
                    arguments: [date.timeIntervalSince1970, key])
            }
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
        }
    }
    public func albumPage(before: AlbumCursor?, limit: Int) throws -> AlbumPage {
        guard (1...40).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            var sql = "SELECT * FROM media_files WHERE album_added_at IS NOT NULL AND state='ready'"
            var arguments: StatementArguments = []
            if let before {
                let key = try BusinessRecordID.number(before.id, kind: .media)
                sql += " AND (COALESCE(captured_at,created_at),id) < (?,?)"
                arguments = [before.date.timeIntervalSince1970, key]
            }
            sql += " ORDER BY COALESCE(captured_at,created_at) DESC,id DESC LIMIT ?"
            arguments += [limit + 1]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            let items = rows.prefix(limit).map(Self.album)
            let next = rows.count > limit ? items.last.map { AlbumCursor(date: $0.sortDate, id: $0.id) } : nil
            return AlbumPage(items: items, next: next)
        }
    }
    public func albumPhoto(_ id: String) throws -> AlbumPhotoRecord? {
        let key = try BusinessRecordID.number(id, kind: .media)
        return try database.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM media_files WHERE id=? AND album_added_at IS NOT NULL AND state='ready'",
                arguments: [key]
            ).map(Self.album)
        }
    }
    public func deletePhoto(_ id: String) throws {
        let key = try BusinessRecordID.number(id, kind: .media)
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE media_files SET state='deleting' WHERE id=? AND album_added_at IS NOT NULL AND state='ready'",
                arguments: [key])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
        }
    }
    public func pendingPhotoDeletions() throws -> [MediaFileRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM media_files WHERE state='deleting' ORDER BY id LIMIT 128").map(
                Self.media)
        }
    }
    private static func album(_ row: Row) -> AlbumPhotoRecord {
        AlbumPhotoRecord(
            id: SQLiteRecordKey.id(.media, row["id"]),
            metadata: PhotoMetadata(
                mime: row["mime"], width: row["photo_width"], height: row["photo_height"],
                capturedAt: (row["captured_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                origin: row["photo_origin"]), addedAt: Date(timeIntervalSince1970: row["album_added_at"]),
            createdAt: Date(timeIntervalSince1970: row["created_at"]), bytes: row["bytes"])
    }
    private static func media(_ row: Row) -> MediaFileRecord {
        MediaFileRecord(
            id: SQLiteRecordKey.id(.media, row["id"]), path: row["relative_path"], bytes: row["bytes"],
            source: row["source"], session: row["session_id"], input: row["input_id"], state: row["state"],
            albumAddedAt: (row["album_added_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }
}
