import Foundation
internal import GRDB

enum SQLiteSchema {
    static let currentVersion = 20_261_112
    static let statements = [
        AgentMessageRow.schemaSQL, AssistantConversationRow.schemaSQL, AssistantTaskRow.schemaSQL,
        WriterWorkspaceRow.schemaSQL, AssistantMessageRow.schemaSQL, SQLiteWriterExecutionRepository.schemaSQL,
        WriterMessageRow.schemaSQL,
        ModelRequestLogRow.schemaSQL, WorkspaceFileRow.schemaSQL, MediaFileRow.schemaSQL, DeviceRow.schemaSQL,
    ]
    static func prepare(_ pool: DatabasePool, resetWriterFilesAt: URL? = nil) throws {
        let installed = try pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        guard installed <= currentVersion else { throw SQLiteSchemaError.unsupportedVersion(installed) }
        if installed == currentVersion { return }
        if [20_261_110, 20_261_111].contains(installed) {
            try migrateRequestMessages(pool)
            return
        }
        // Explicitly approved clean format replacement. No legacy data or compatibility schema remains.
        if let root = resetWriterFilesAt {
            guard root.isFileURL else { throw CocoaError(.fileReadInvalidFileName) }
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        try pool.erase()
        try pool.write { db in
            for statement in statements { try db.execute(sql: statement) }
            try db.execute(
                sql:
                    "CREATE INDEX IF NOT EXISTS assistant_input_batch ON assistant_messages(json_extract(user_input_json, '$.coordination.batchID'))"
            )
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }
    }
    private static func migrateRequestMessages(_ pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys=OFF")
            do {
                try db.inTransaction {
                    try db.execute(sql: "DROP INDEX IF EXISTS single_writer_execution")
                    try db.execute(sql: SQLiteWriterExecutionRepository.schemaSQL)
                    let executionColumns =
                        "id,request_message_id,selected_workspace_id,user_input_json,request_goal,run_state,terminal_state,request_revision,pending_question_id,pending_question_json,result_json,failure_json,runtime_results_json,created_at,updated_at,completed_at"
                    try db.execute(
                        sql:
                            "INSERT INTO writer_executions(\(executionColumns)) SELECT \(executionColumns) FROM writer_messages WHERE input_kind='delegation'"
                    )
                    let schema = WriterMessageRow.schemaSQL.split(separator: ";").map(String.init)
                    try db.execute(
                        sql: schema[0].replacingOccurrences(
                            of: "CREATE TABLE writer_messages(", with: "CREATE TABLE writer_messages_new("))
                    let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(writer_messages_new)").map {
                        $0["name"] as String
                    }.joined(separator: ",")
                    try db.execute(
                        sql:
                            "INSERT INTO writer_messages_new(\(columns)) SELECT \(columns) FROM writer_messages WHERE input_kind!='delegation' AND json_extract(assistant_response_json,'$.id') IS NOT NULL"
                    )
                    try db.execute(
                        sql:
                            "DELETE FROM model_request_log WHERE writer_message_id IS NOT NULL AND writer_message_id NOT IN (SELECT id FROM writer_messages_new)"
                    )
                    try db.execute(sql: "DROP TABLE writer_messages")
                    try db.execute(sql: "ALTER TABLE writer_messages_new RENAME TO writer_messages")
                    for index in schema.dropFirst() where !index.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        try db.execute(sql: index)
                    }
                    try db.execute(
                        sql:
                            "UPDATE writer_messages SET caused_by_message_id=NULL WHERE caused_by_message_id NOT IN (SELECT id FROM writer_messages)"
                    )
                    try db.execute(
                        sql:
                            "DELETE FROM model_request_log WHERE assistant_message_id IN (SELECT id FROM assistant_messages WHERE json_extract(assistant_response_json,'$.id') IS NULL)"
                    )
                    try db.execute(
                        sql: "DELETE FROM assistant_messages WHERE json_extract(assistant_response_json,'$.id') IS NULL"
                    )
                    try db.execute(
                        sql:
                            "UPDATE assistant_messages SET caused_by_message_id=NULL WHERE caused_by_message_id NOT IN (SELECT id FROM assistant_messages)"
                    )
                    try db.execute(
                        sql:
                            "CREATE INDEX IF NOT EXISTS assistant_input_batch ON assistant_messages(json_extract(user_input_json,'$.coordination.batchID'))"
                    )
                    guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                        throw SQLiteSchemaError.invalidMigration
                    }
                    try db.execute(sql: "PRAGMA user_version=\(currentVersion)")
                    return .commit
                }
                try db.execute(sql: "PRAGMA foreign_keys=ON")
            } catch {
                try db.execute(sql: "PRAGMA foreign_keys=ON")
                throw error
            }
        }
    }

}
enum SQLiteSchemaError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidMigration
}
