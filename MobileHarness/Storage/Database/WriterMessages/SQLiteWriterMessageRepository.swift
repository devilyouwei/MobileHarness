import Foundation
internal import GRDB
import StorageChat
import StorageCore

public final class SQLiteWriterMessageRepository: WriterMessageRepository {
    public var storageScope: UUID { database.storageScope }
    let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }
    struct Owner {
        let key: Int64
        var table: String { "writer_messages" }
        var column: String { request ? "delegation_id" : "workspace_id" }
        var request: Bool = false
        var preflight: Bool = false
        var resultsColumn: String { "runtime_results_json" }
        var id: String { request ? "writer/request_\(key)" : "workspace_\(key)" }
    }
    static func owner(_ id: String, db: Database) throws -> Owner {
        if id.hasPrefix("writer/preflight_"), let key = Int64(id.dropFirst("writer/preflight_".count)) {
            return Owner(key: key, request: true, preflight: true)
        }
        if id.hasPrefix("writer/request_"), let key = Int64(id.dropFirst("writer/request_".count)),
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM writer_executions WHERE id=?", arguments: [key]
            ) == 1
        {
            return Owner(key: key, request: true)
        }
        guard let workspace = WorkspaceID(rawValue: id), workspace.agent == "writer" else {
            throw RecordStorageError.invalidID
        }
        let key = try BusinessRecordID.number(workspace.rawValue, kind: .workspace)
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM writer_workspaces WHERE id=?", arguments: [key]) == 1
        else { throw RecordStorageError.missingRecord }
        return Owner(key: key)
    }
    static func locate(_ key: Int64, db: Database) throws -> (Owner, Row) {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM writer_messages WHERE id=?", arguments: [key]),
            let owner: Int64 = row["delegation_id"]
        else { throw RecordStorageError.missingRecord }
        return (Owner(key: owner, request: true), row)
    }
    internal func recoverInFlight() throws { try database.write { try Self.recoverWriterMessages($0) } }
}

extension SQLiteWriterMessageRepository {
    static func saveWriterDetails(_ decision: [String: Any], message: Int64, db: Database) throws {
        guard !decision.isEmpty else { return }
        let catalog = try SQLiteRecordCoding.object(decision["catalogJSON"] as? String ?? "{}")
        try db.execute(
            sql: "UPDATE writer_messages SET phase=?,target_path=?,tool_catalog_json=? WHERE id=?",
            arguments: [
                decision["mode"] as? String, decision["targetPath"] as? String,
                try SQLiteRecordCoding.json(catalog["tools"] ?? []),
                message,
            ])
    }
    static func recoverWriterMessages(_ db: Database) throws {
        try db.execute(
            sql: "UPDATE writer_messages SET state='interrupted',completed_at=?,updated_at=? WHERE state='generating'",
            arguments: [Date().timeIntervalSince1970, Date().timeIntervalSince1970])
    }

    static func saveWriterRoundResult(_ result: [String: Any], ownerID: Int64, invocation: String, db: Database) throws
    {
        let saved =
            try String.fetchOne(
                db,
                sql:
                    "SELECT runtime_results_json FROM writer_messages WHERE delegation_id=? AND json_extract(assistant_response_json,'$.id')=?",
                arguments: [ownerID, invocation]) ?? "[]"
        let markers = (try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [[String: Any]] ?? []).filter {
            $0["kind"] as? String == "completion"
        }
        try db.execute(
            sql:
                "UPDATE writer_messages SET runtime_results_json=? WHERE delegation_id=? AND json_extract(assistant_response_json,'$.id')=?",
            arguments: [try SQLiteRecordCoding.json([result] + markers), ownerID, invocation])
        guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
    }

    static func writerMessageDecision(_ row: Row) throws -> WriterDecisionMetadata {
        var decision = WriterDecisionMetadata(
            workspaceID: (row["workspace_id"] as Int64?).map { "workspace_\($0)" },
            mode: row["phase"] as String? ?? "control",
            skills: [:],
            catalogJSON: try SQLiteRecordCoding.json([
                "actions": [],
                "tools": JSONSerialization.jsonObject(with: Data((row["tool_catalog_json"] as String).utf8)),
            ]), execution: "background")
        decision.delegateID = row["request_message_id"]
        return decision
    }

}

extension SQLiteWriterMessageRepository {
    @discardableResult public func save(ownerID id: String, revision: UInt64, messages: [WriterMessageRecord]) throws
        -> [WriterMessageReference]
    {
        guard revision <= Int64.max else { throw RecordStorageError.invalidRecord }
        return try database.write { db in
            let owner = try Self.owner(id, db: db)
            let references = try messages.map { try Self.saveMessage($0, owner: owner, db: db) }

            try db.execute(
                sql: "UPDATE writer_executions SET request_revision=MAX(request_revision+1,?) WHERE id=?",
                arguments: [Int64(revision), owner.key])
            return references
        }
    }
}
