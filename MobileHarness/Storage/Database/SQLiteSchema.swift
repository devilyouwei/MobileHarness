import Foundation
internal import GRDB

enum SQLiteSchema {
    static let currentVersion = 20_261_110
    static let statements = [
        AgentMessageRow.schemaSQL, AssistantConversationRow.schemaSQL, AssistantTaskRow.schemaSQL,
        WriterWorkspaceRow.schemaSQL, AssistantMessageRow.schemaSQL, WriterMessageRow.schemaSQL,
        ModelRequestLogRow.schemaSQL, WorkspaceFileRow.schemaSQL, MediaFileRow.schemaSQL, DeviceRow.schemaSQL,
    ]
    static func prepare(_ pool: DatabasePool, resetWriterFilesAt: URL? = nil) throws {
        let installed = try pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        guard installed <= currentVersion else { throw SQLiteSchemaError.unsupportedVersion(installed) }
        if installed == currentVersion { return }
        // Explicitly approved clean format replacement. No legacy data or compatibility schema remains.
        if let root = resetWriterFilesAt {
            guard root.isFileURL else { throw CocoaError(.fileReadInvalidFileName) }
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        try pool.erase()
        try pool.write { db in
            for statement in statements { try db.execute(sql: statement) }
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }
    }
}
enum SQLiteSchemaError: Error, Equatable { case unsupportedVersion(Int) }
