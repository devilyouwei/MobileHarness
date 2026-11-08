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
        dedupe_key TEXT NOT NULL,
        delivery_state TEXT NOT NULL DEFAULT 'pending' CHECK(delivery_state IN ('pending','in_flight','received','dead_letter')),
        created_at REAL NOT NULL,
        received_at REAL,
        consumed_at REAL,
        attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count BETWEEN 0 AND 8),
        next_attempt_at REAL,
        last_error TEXT,
        claim_token TEXT,
        claim_expires_at REAL ,
        UNIQUE(sender_agent_id,receiver_agent_id,dedupe_key));
        CREATE INDEX agent_message_delivery ON agent_messages(receiver_agent_id,delivery_state,next_attempt_at,created_at);
        CREATE INDEX agent_message_correlation ON agent_messages(correlation_id,created_at);
        CREATE INDEX agent_message_reply ON agent_messages(reply_to_id);
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
    var dedupeKey: String
    var deliveryState: String = "pending"
    var createdAt: Double
    var receivedAt: Double? = nil
    var consumedAt: Double? = nil
    var attemptCount: Int64 = 0
    var nextAttemptAt: Double? = nil
    var lastError: String? = nil
    var claimToken: String? = nil
    var claimExpiresAt: Double? = nil
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
        case dedupeKey = "dedupe_key"
        case deliveryState = "delivery_state"
        case createdAt = "created_at"
        case receivedAt = "received_at"
        case consumedAt = "consumed_at"
        case attemptCount = "attempt_count"
        case nextAttemptAt = "next_attempt_at"
        case lastError = "last_error"
        case claimToken = "claim_token"
        case claimExpiresAt = "claim_expires_at"
    }
}
