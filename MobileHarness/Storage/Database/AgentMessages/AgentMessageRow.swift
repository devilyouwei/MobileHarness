import Foundation
internal import GRDB

struct AgentMessageRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "agent_messages"
    static let schemaSQL = """
        CREATE TABLE agent_messages(
        id TEXT PRIMARY KEY NOT NULL,
        sender_agent_id TEXT NOT NULL,
        receiver_agent_id TEXT NOT NULL,
        contract TEXT NOT NULL,
        schema_version INTEGER NOT NULL DEFAULT 1,
        payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
        correlation_id TEXT NOT NULL,
        reply_to_id TEXT REFERENCES agent_messages(id) ON DELETE RESTRICT,
        sender_context TEXT,
        source_session_id TEXT,
        dedupe_key TEXT NOT NULL,
        created_at REAL NOT NULL,
        received_at REAL,
        consumed_at REAL,
        UNIQUE(sender_agent_id,receiver_agent_id,dedupe_key));
        CREATE INDEX agent_message_receiver ON agent_messages(receiver_agent_id,created_at);
        CREATE INDEX agent_message_correlation ON agent_messages(correlation_id,created_at);
        CREATE INDEX agent_message_reply ON agent_messages(reply_to_id);
        """
    static let evidenceSchemaSQL = """
        CREATE TABLE invocation_evidence(
            id TEXT PRIMARY KEY NOT NULL,
            owner_context TEXT NOT NULL,
            payload BLOB NOT NULL,
            created_at REAL NOT NULL);
        CREATE INDEX invocation_evidence_owner ON invocation_evidence(owner_context);
        """
    var id: String
    var senderAgentID: String
    var receiverAgentID: String
    var contract: String
    var schemaVersion: Int64 = 1
    var payloadJson: String
    var correlationID: String
    var replyToID: String? = nil
    var senderContext: String? = nil
    var sourceSessionID: String? = nil
    var dedupeKey: String
    var createdAt: Double
    var receivedAt: Double? = nil
    var consumedAt: Double? = nil
    enum CodingKeys: String, CodingKey {
        case id
        case senderAgentID = "sender_agent_id"
        case receiverAgentID = "receiver_agent_id"
        case contract
        case schemaVersion = "schema_version"
        case payloadJson = "payload_json"
        case correlationID = "correlation_id"
        case replyToID = "reply_to_id"
        case senderContext = "sender_context"
        case sourceSessionID = "source_session_id"
        case dedupeKey = "dedupe_key"
        case createdAt = "created_at"
        case receivedAt = "received_at"
        case consumedAt = "consumed_at"
    }
}
