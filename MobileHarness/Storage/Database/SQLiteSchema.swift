import Foundation
internal import GRDB

enum SQLiteSchema {
    static let currentVersion = 20_261_122
    static let statements = [
        AgentMessageRow.schemaSQL, AgentMessageRow.evidenceSchemaSQL, AssistantConversationRow.schemaSQL,
        AssistantTaskRow.schemaSQL,
        WriterWorkspaceRow.schemaSQL, AssistantMessageRow.schemaSQL, SQLiteWriterExecutionRepository.schemaSQL,
        WriterMessageRow.schemaSQL,
        ModelRequestLogRow.schemaSQL, WorkspaceFileRow.schemaSQL, MediaFileRow.schemaSQL, DeviceRow.schemaSQL,
    ]
    static func prepare(_ pool: DatabasePool, resetWriterFilesAt: URL? = nil) throws {
        let installed = try pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        if installed == currentVersion { return }
        // Any other version is replaced; stored data is never migrated.
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
}
