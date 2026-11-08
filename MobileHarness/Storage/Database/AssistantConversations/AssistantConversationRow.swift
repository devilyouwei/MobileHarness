import Foundation
internal import GRDB

struct AssistantConversationRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "assistant_conversations"
    static let schemaSQL = """
        CREATE TABLE assistant_conversations(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        created_at REAL NOT NULL,
        archived_at REAL,
        revision INTEGER NOT NULL DEFAULT 0);
        CREATE UNIQUE INDEX current_conversation ON assistant_conversations((1)) WHERE archived_at IS NULL;
        """
    var id: Int64? = nil
    var title: String? = nil
    var createdAt: Double
    var archivedAt: Double? = nil
    var revision: Int64 = 0
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt = "created_at"
        case archivedAt = "archived_at"
        case revision
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
