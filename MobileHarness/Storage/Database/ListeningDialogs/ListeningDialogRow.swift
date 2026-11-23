import Foundation
internal import GRDB

struct ListeningDialogRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "listening_dialogs"
    static let schemaSQL = """
        CREATE TABLE listening_dialogs(
        id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT NOT NULL,
        episode_id TEXT NOT NULL,
        asr_text TEXT NOT NULL,
        decision TEXT NOT NULL CHECK(decision IN ('stay','exit','error')),
        reason TEXT,
        model_tier TEXT,
        model_id TEXT,
        latency_ms INTEGER NOT NULL CHECK(latency_ms >= 0),
        error TEXT,
        created_at REAL NOT NULL);
        CREATE INDEX listening_dialog_episode ON listening_dialogs(episode_id,created_at);
        CREATE INDEX listening_dialog_created ON listening_dialogs(created_at);
        """
    var id: String
    var sessionID: String
    var episodeID: String
    var asrText: String
    var decision: String
    var reason: String?
    var modelTier: String?
    var modelID: String?
    var latencyMS: Int64
    var error: String?
    var createdAt: Double
    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case episodeID = "episode_id"
        case asrText = "asr_text"
        case decision, reason
        case modelTier = "model_tier"
        case modelID = "model_id"
        case latencyMS = "latency_ms"
        case error
        case createdAt = "created_at"
    }
}
