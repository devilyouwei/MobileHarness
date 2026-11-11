import Foundation
internal import GRDB
import StorageCore
import StorageTasks

public final class SQLiteWriterExecutionRepository: WriterExecutionRepository {
    static let schemaSQL = """
        CREATE TABLE writer_executions(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        request_message_id TEXT NOT NULL UNIQUE REFERENCES agent_messages(id) ON DELETE RESTRICT,
        selected_workspace_id INTEGER REFERENCES writer_workspaces(id) ON DELETE RESTRICT,
        user_input_json TEXT NOT NULL CHECK(json_valid(user_input_json)),
        request_goal TEXT NOT NULL,
        run_state TEXT NOT NULL,
        terminal_state TEXT,
        request_revision INTEGER NOT NULL DEFAULT 0,
        pending_question_id TEXT REFERENCES agent_messages(id) ON DELETE RESTRICT,
        pending_question_json TEXT CHECK(pending_question_json IS NULL OR json_valid(pending_question_json)),
        result_json TEXT CHECK(result_json IS NULL OR json_valid(result_json)),
        failure_json TEXT,
        runtime_results_json TEXT NOT NULL DEFAULT '[]',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        completed_at REAL);
        CREATE UNIQUE INDEX single_writer_execution ON writer_executions((1))
        WHERE run_state IN ('running','waiting_input','paused','closing','cleanup_failed');
        """

    public var storageScope: UUID { database.storageScope }
    let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }
    internal func recoverInFlight() throws { try database.write { try Self.recoverWriterExecutions($0) } }
}
