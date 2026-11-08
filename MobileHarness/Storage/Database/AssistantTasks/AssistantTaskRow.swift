import Foundation
internal import GRDB

struct AssistantTaskRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "assistant_tasks"
    static let schemaSQL = """
        CREATE TABLE assistant_tasks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL REFERENCES assistant_conversations(id) ON DELETE CASCADE,
        description TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'running',
        end_reason TEXT,
        started_at REAL NOT NULL,
        ended_at REAL,
        summary TEXT,
        source_revision INTEGER NOT NULL DEFAULT 0,
        summary_revision INTEGER,
        failure_json TEXT);
        CREATE UNIQUE INDEX single_foreground_task ON assistant_tasks((1)) WHERE state IN ('running','finishing','closing','cleanup_failed');
        CREATE INDEX assistant_task_conversation ON assistant_tasks(conversation_id,id);
        """
    var id: Int64? = nil
    var conversationID: Int64
    var description: String
    var state: String = "running"
    var endReason: String? = nil
    var startedAt: Double
    var endedAt: Double? = nil
    var summary: String? = nil
    var sourceRevision: Int64 = 0
    var summaryRevision: Int64? = nil
    var failureJson: String? = nil
    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case description
        case state
        case endReason = "end_reason"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case summary
        case sourceRevision = "source_revision"
        case summaryRevision = "summary_revision"
        case failureJson = "failure_json"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
