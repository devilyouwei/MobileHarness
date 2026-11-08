import Foundation
internal import GRDB
import StorageDatabase

/// The persisted columns and schema owned by workspace_files; never exposed to application consumers.
struct WorkspaceFileRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "workspace_files"
    static let schemaSQL = """
        CREATE TABLE workspace_files(task_id INTEGER NOT NULL REFERENCES writer_workspaces(id) ON DELETE CASCADE,
        path TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>=0),fingerprint TEXT NOT NULL,updated_at REAL NOT NULL,
        PRIMARY KEY(task_id,path));
        """
    var taskID: Int64
    var path: String
    var bytes: Int64
    var fingerprint: String
    var updatedAt: Double
    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case path
        case bytes
        case fingerprint
        case updatedAt = "updated_at"
    }
}

extension WorkspaceFileRow {
    static func files(_ db: Database, taskID: Int64) throws -> [WorkspaceFile] {
        try filter(Column("task_id") == taskID).order(Column("path")).fetchAll(db).map {
            .init(path: $0.path, bytes: Int($0.bytes), fingerprint: $0.fingerprint)
        }
    }
    static func replace(_ db: Database, taskID: Int64, files: [WorkspaceFile]) throws {
        try filter(Column("task_id") == taskID).deleteAll(db)
        for file in files {
            var row = Self(
                taskID: taskID, path: file.path, bytes: Int64(file.bytes), fingerprint: file.fingerprint,
                updatedAt: Date().timeIntervalSince1970)
            try row.insert(db)
        }
    }
}
