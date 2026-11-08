import Foundation
internal import GRDB

struct ModelRequestLogRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "model_request_log"
    static let schemaSQL = """
        CREATE TABLE model_request_log(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        assistant_message_id INTEGER REFERENCES assistant_messages(id) ON DELETE CASCADE,
        writer_message_id INTEGER REFERENCES writer_messages(id) ON DELETE CASCADE,
        assistant_conversation_id INTEGER REFERENCES assistant_conversations(id) ON DELETE CASCADE,
        invocation_id TEXT NOT NULL,
        transport_index INTEGER NOT NULL DEFAULT 0,
        method TEXT,
        url TEXT,
        request_headers_json TEXT NOT NULL DEFAULT '{}',
        request_body BLOB NOT NULL DEFAULT X'',
        http_status INTEGER,
        response_headers_json TEXT NOT NULL DEFAULT '{}',
        response_body BLOB NOT NULL DEFAULT X'',
        started_at REAL,
        first_byte_at REAL,
        completed_at REAL,
        generation_meta_json TEXT NOT NULL DEFAULT '{}',
        capture_format TEXT NOT NULL DEFAULT 'local',
        capture_state TEXT NOT NULL DEFAULT 'capturing',
        capture_details_json TEXT NOT NULL DEFAULT '{}',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        schema_version INTEGER NOT NULL DEFAULT 1 ,
        CHECK((assistant_message_id IS NOT NULL)+(writer_message_id IS NOT NULL)+(assistant_conversation_id IS NOT NULL)=1),
        UNIQUE(invocation_id,transport_index));
        CREATE INDEX log_assistant ON model_request_log(assistant_message_id,id);
        CREATE INDEX log_writer ON model_request_log(writer_message_id,id);
        CREATE INDEX log_conversation ON model_request_log(assistant_conversation_id,id);
        """
    var id: Int64? = nil
    var assistantMessageID: Int64? = nil
    var writerMessageID: Int64? = nil
    var assistantConversationID: Int64? = nil
    var invocationID: String
    var transportIndex: Int64 = 0
    var method: String? = nil
    var url: String? = nil
    var requestHeadersJson: String = "{}"
    var requestBody: Data = Data()
    var httpStatus: Int64? = nil
    var responseHeadersJson: String = "{}"
    var responseBody: Data = Data()
    var startedAt: Double? = nil
    var firstByteAt: Double? = nil
    var completedAt: Double? = nil
    var generationMetaJson: String = "{}"
    var captureFormat: String = "local"
    var captureState: String = "capturing"
    var captureDetailsJson: String = "{}"
    var createdAt: Double
    var updatedAt: Double
    var schemaVersion: Int64 = 1
    enum CodingKeys: String, CodingKey {
        case id
        case assistantMessageID = "assistant_message_id"
        case writerMessageID = "writer_message_id"
        case assistantConversationID = "assistant_conversation_id"
        case invocationID = "invocation_id"
        case transportIndex = "transport_index"
        case method
        case url
        case requestHeadersJson = "request_headers_json"
        case requestBody = "request_body"
        case httpStatus = "http_status"
        case responseHeadersJson = "response_headers_json"
        case responseBody = "response_body"
        case startedAt = "started_at"
        case firstByteAt = "first_byte_at"
        case completedAt = "completed_at"
        case generationMetaJson = "generation_meta_json"
        case captureFormat = "capture_format"
        case captureState = "capture_state"
        case captureDetailsJson = "capture_details_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case schemaVersion = "schema_version"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
