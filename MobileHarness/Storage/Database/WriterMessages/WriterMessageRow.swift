import Foundation
internal import GRDB

struct WriterMessageRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "writer_messages"
    static let schemaSQL = """
        CREATE TABLE writer_messages(
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
        workspace_id INTEGER REFERENCES writer_workspaces(id) ON DELETE RESTRICT,
        request_message_id TEXT REFERENCES agent_messages(id) ON DELETE RESTRICT,
        delegation_id INTEGER REFERENCES writer_messages(id) ON DELETE RESTRICT,
        selected_workspace_id INTEGER REFERENCES writer_workspaces(id) ON DELETE RESTRICT,
        run_state TEXT,
        request_goal TEXT,
        request_revision INTEGER NOT NULL DEFAULT 0,
        pending_question_id TEXT REFERENCES agent_messages(id) ON DELETE RESTRICT,
        pending_question_json TEXT CHECK(pending_question_json IS NULL OR json_valid(pending_question_json)),
        failure_json TEXT,
        terminal_state TEXT,
        result_json TEXT CHECK(result_json IS NULL OR json_valid(result_json)),
        caused_by_message_id INTEGER REFERENCES writer_messages(id) ON DELETE SET NULL,
        phase TEXT,
        target_path TEXT,
        runtime_results_json TEXT NOT NULL DEFAULT '[]' ,
        CHECK(request_message_id IS NOT NULL),
        CHECK((input_kind='delegation' AND delegation_id IS NULL AND workspace_id IS NULL AND run_state IS NOT NULL) OR (input_kind!='delegation' AND delegation_id IS NOT NULL AND run_state IS NULL)),
        UNIQUE(input_key));
        CREATE UNIQUE INDEX writer_delegation_identity ON writer_messages(request_message_id) WHERE input_kind='delegation';
        CREATE UNIQUE INDEX single_writer_execution ON writer_messages((1)) WHERE input_kind='delegation' AND run_state IN ('running','waiting_input','paused','closing','cleanup_failed');
        CREATE INDEX writer_message_delegation ON writer_messages(delegation_id,id);
        CREATE INDEX writer_message_order ON writer_messages(workspace_id,position,id);
        CREATE INDEX writer_message_request ON writer_messages(request_message_id,position,id);
        CREATE INDEX writer_message_root ON writer_messages(root_input_key);
        CREATE INDEX writer_message_cause ON writer_messages(caused_by_message_id);
        CREATE UNIQUE INDEX writer_message_invocation ON writer_messages(json_extract(assistant_response_json,'$.id')) WHERE json_extract(assistant_response_json,'$.id') IS NOT NULL;
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
    var workspaceID: Int64? = nil
    var delegationID: Int64? = nil
    var selectedWorkspaceID: Int64? = nil
    var runState: String? = nil
    var requestGoal: String? = nil
    var requestRevision: Int64 = 0
    var pendingQuestionID: String? = nil
    var pendingQuestionJson: String? = nil
    var failureJson: String? = nil
    var terminalState: String? = nil
    var resultJson: String? = nil
    var requestMessageID: String? = nil
    var causedByMessageID: Int64? = nil
    var phase: String? = nil
    var targetPath: String? = nil
    var runtimeResultsJson: String = "[]"
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
        case workspaceID = "workspace_id"
        case delegationID = "delegation_id"
        case selectedWorkspaceID = "selected_workspace_id"
        case runState = "run_state"
        case requestGoal = "request_goal"
        case requestRevision = "request_revision"
        case pendingQuestionID = "pending_question_id"
        case pendingQuestionJson = "pending_question_json"
        case failureJson = "failure_json"
        case terminalState = "terminal_state"
        case resultJson = "result_json"
        case requestMessageID = "request_message_id"
        case causedByMessageID = "caused_by_message_id"
        case phase
        case targetPath = "target_path"
        case runtimeResultsJson = "runtime_results_json"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
