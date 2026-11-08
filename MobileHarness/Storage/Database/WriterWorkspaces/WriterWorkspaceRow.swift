import Foundation
internal import GRDB

struct WriterWorkspaceRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "writer_workspaces"
    static let schemaSQL = """
        CREATE TABLE writer_workspaces(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        description TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        entry TEXT NOT NULL DEFAULT 'index.html',
        revision INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        workspace_state TEXT NOT NULL DEFAULT 'absent' CHECK(workspace_state IN ('absent','ready','deleting','deleted')),
        workspace_token TEXT,
        write_lease TEXT,
        has_draft INTEGER NOT NULL DEFAULT 0 CHECK(has_draft IN (0,1)),
        index_needs_recovery INTEGER NOT NULL DEFAULT 0 CHECK(index_needs_recovery IN (0,1)),
        deleted_at REAL);
        """
    var id: Int64? = nil
    var description: String
    var title: String = ""
    var entry: String = "index.html"
    var revision: Int64 = 0
    var createdAt: Double
    var updatedAt: Double
    var workspaceState: String = "absent"
    var workspaceToken: String? = nil
    var writeLease: String? = nil
    var hasDraft: Int64 = 0
    var indexNeedsRecovery: Int64 = 0
    enum CodingKeys: String, CodingKey {
        case id
        case description
        case title
        case entry
        case revision
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case workspaceState = "workspace_state"
        case workspaceToken = "workspace_token"
        case writeLease = "write_lease"
        case hasDraft = "has_draft"
        case indexNeedsRecovery = "index_needs_recovery"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
