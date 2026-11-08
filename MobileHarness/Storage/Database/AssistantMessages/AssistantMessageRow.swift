import Foundation
internal import GRDB

struct AssistantMessageRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "assistant_messages"
    static let schemaSQL = """
        CREATE TABLE assistant_messages(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        input_key TEXT NOT NULL,
        root_input_key TEXT NOT NULL,
        position INTEGER NOT NULL CHECK(position>=0),
        input_kind TEXT NOT NULL DEFAULT 'user',
        state TEXT NOT NULL DEFAULT 'generating',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        completed_at REAL,
        schema_version INTEGER NOT NULL DEFAULT 1,
        user_input_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(user_input_json)),
        assistant_response_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(assistant_response_json)),
        tool_catalog_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(tool_catalog_json)),
        tool_calls_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(tool_calls_json)),
        conversation_id INTEGER NOT NULL REFERENCES assistant_conversations(id) ON DELETE CASCADE,
        task_id INTEGER REFERENCES assistant_tasks(id) ON DELETE SET NULL,
        source_agent_message_id TEXT REFERENCES agent_messages(id) ON DELETE RESTRICT,
        caused_by_message_id INTEGER REFERENCES assistant_messages(id) ON DELETE SET NULL,
        skills_json TEXT NOT NULL DEFAULT '{}',
        action_catalog_json TEXT NOT NULL DEFAULT '[]',
        action_results_json TEXT NOT NULL DEFAULT '[]',
        decision_json TEXT NOT NULL DEFAULT '{}' ,
        UNIQUE(conversation_id,input_key));
        CREATE INDEX assistant_message_order ON assistant_messages(conversation_id,position,id);
        CREATE INDEX assistant_message_task ON assistant_messages(task_id,position,id);
        CREATE INDEX assistant_message_root ON assistant_messages(root_input_key);
        CREATE INDEX assistant_message_cause ON assistant_messages(caused_by_message_id);
        CREATE INDEX assistant_message_source ON assistant_messages(source_agent_message_id);
        CREATE UNIQUE INDEX assistant_message_invocation ON assistant_messages(json_extract(assistant_response_json,'$.id')) WHERE json_extract(assistant_response_json,'$.id') IS NOT NULL;
        """
    var id: Int64? = nil
    var inputKey: String
    var rootInputKey: String
    var position: Int64
    var inputKind: String = "user"
    var state: String = "generating"
    var createdAt: Double
    var updatedAt: Double
    var completedAt: Double? = nil
    var schemaVersion: Int64 = 1
    var userInputJson: String = "{}"
    var assistantResponseJson: String = "{}"
    var toolCatalogJson: String = "[]"
    var toolCallsJson: String = "[]"
    var conversationID: Int64
    var taskID: Int64? = nil
    var sourceAgentMessageID: String? = nil
    var causedByMessageID: Int64? = nil
    var skillsJson: String = "{}"
    var actionCatalogJson: String = "[]"
    var actionResultsJson: String = "[]"
    var decisionJson: String = "{}"
    enum CodingKeys: String, CodingKey {
        case id
        case inputKey = "input_key"
        case rootInputKey = "root_input_key"
        case position
        case inputKind = "input_kind"
        case state
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case schemaVersion = "schema_version"
        case userInputJson = "user_input_json"
        case assistantResponseJson = "assistant_response_json"
        case toolCatalogJson = "tool_catalog_json"
        case toolCallsJson = "tool_calls_json"
        case conversationID = "conversation_id"
        case taskID = "task_id"
        case sourceAgentMessageID = "source_agent_message_id"
        case causedByMessageID = "caused_by_message_id"
        case skillsJson = "skills_json"
        case actionCatalogJson = "action_catalog_json"
        case actionResultsJson = "action_results_json"
        case decisionJson = "decision_json"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
