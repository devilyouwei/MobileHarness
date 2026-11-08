import Foundation
internal import GRDB

/// The persisted columns and schema owned by media_files; never exposed to application consumers.
struct MediaFileRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "media_files"
    static let schemaSQL = """
        CREATE TABLE media_files(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, mime TEXT NOT NULL,
        relative_path TEXT NOT NULL UNIQUE, bytes INTEGER NOT NULL, source TEXT NOT NULL,
        session_id TEXT NOT NULL, input_id TEXT NOT NULL, created_at REAL NOT NULL, captured_at REAL,
        state TEXT NOT NULL, failure TEXT,album_added_at REAL,photo_width INTEGER,photo_height INTEGER,photo_origin TEXT);
        CREATE INDEX media_owner ON media_files(source,input_id,id);
        CREATE INDEX media_retention ON media_files(state,created_at,id);
        CREATE INDEX album_order ON media_files(COALESCE(captured_at,created_at) DESC,id DESC)
        WHERE album_added_at IS NOT NULL AND state='ready';
        """
    var id: Int64? = nil
    var kind: String
    var mime: String
    var relativePath: String
    var bytes: Int64
    var source: String
    var sessionID: String
    var inputID: String
    var createdAt: Double
    var capturedAt: Double? = nil
    var state: String
    var failure: String? = nil
    var albumAddedAt: Double? = nil
    var photoWidth: Int64? = nil
    var photoHeight: Int64? = nil
    var photoOrigin: String? = nil
    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case mime
        case relativePath = "relative_path"
        case bytes
        case source
        case sessionID = "session_id"
        case inputID = "input_id"
        case createdAt = "created_at"
        case capturedAt = "captured_at"
        case state
        case failure
        case albumAddedAt = "album_added_at"
        case photoWidth = "photo_width"
        case photoHeight = "photo_height"
        case photoOrigin = "photo_origin"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
