import Foundation
internal import GRDB
import StorageChat
import StorageCore

extension SQLiteAssistantConversationRepository {
    static func conversation(_ row: Row, db: Database) throws -> AssistantConversationRecord {
        let key: Int64 = row["id"]
        return AssistantConversationRecord(
            id: "dialog_\(key)", createdAt: Date(timeIntervalSince1970: row["created_at"]),
            archivedAt: (row["archived_at"] as Double?).map(Date.init(timeIntervalSince1970:)), title: row["title"],
            titleError: try String.fetchOne(
                db,
                sql:
                    "SELECT COALESCE(json_extract(generation_meta_json,'$.titleError'),json_extract(generation_meta_json,'$.error')) FROM model_request_log WHERE assistant_conversation_id=? ORDER BY id DESC LIMIT 1",
                arguments: [key]), revision: UInt64(row["revision"] as Int64),
            count: try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM assistant_messages WHERE conversation_id=? AND input_kind='user'",
                arguments: [key]) ?? 0,
            latestUser: try String.fetchOne(
                db,
                sql:
                    "SELECT substr(json_extract(user_input_json,'$.text'),1,80) FROM assistant_messages WHERE conversation_id=? AND input_kind='user' ORDER BY position DESC,id DESC LIMIT 1",
                arguments: [key]), traceID: SQLiteRecordKey.traceIdentity(key, namespace: 1))
    }
    public func current() throws -> AssistantConversationRecord {
        if let current = try database.read({ db in
            try Row.fetchOne(db, sql: "SELECT * FROM assistant_conversations WHERE archived_at IS NULL").map {
                try Self.conversation($0, db: db)
            }
        }) {
            return current
        }
        return try database.write { db in
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assistant_conversations WHERE archived_at IS NULL") == 0
            {
                try db.execute(
                    sql: "INSERT INTO assistant_conversations(created_at) VALUES(?)",
                    arguments: [Date().timeIntervalSince1970])
            }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM assistant_conversations WHERE archived_at IS NULL")
            else { throw RecordStorageError.missingRecord }
            return try Self.conversation(row, db: db)
        }
    }
    public func dialog(_ id: String) throws -> AssistantConversationRecord {
        try database.read { db in
            let key = try BusinessRecordID.number(id, kind: .dialog)
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM assistant_conversations WHERE id=?", arguments: [key])
            else { throw RecordStorageError.missingRecord }
            return try Self.conversation(row, db: db)
        }
    }
    public func listDialogs(before: Int64? = nil, limit: Int = HistoryPaging.pageSize) throws
        -> [AssistantConversationRecord]
    {
        guard (1...50).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM assistant_conversations WHERE archived_at IS NOT NULL AND id<? ORDER BY id DESC LIMIT ?",
                arguments: [before ?? Int64.max, limit]
            ).map { try Self.conversation($0, db: db) }
        }
    }
    public func rotate(_ id: String) throws -> AssistantConversationRecord {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        try database.write { db in
            guard
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM assistant_tasks WHERE conversation_id=? AND state IN ('running','finishing','closing','cleanup_failed')",
                    arguments: [key]) == 0
            else { throw RecordStorageError.busy }
            try db.execute(
                sql: "UPDATE assistant_conversations SET archived_at=? WHERE id=? AND archived_at IS NULL",
                arguments: [Date().timeIntervalSince1970, key])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
            try db.execute(
                sql: "INSERT INTO assistant_conversations(created_at) VALUES(?)",
                arguments: [Date().timeIntervalSince1970])
        }
        return try current()
    }
    public func setTitle(_ title: String?, error: String?, dialog id: String) throws {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        try database.write { db in
            try db.execute(
                sql: "UPDATE assistant_conversations SET title=?,revision=revision+1 WHERE id=?",
                arguments: [title, key])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
            if let error {
                let now = Date().timeIntervalSince1970
                var log = ModelRequestLogRow(
                    assistantConversationID: key, invocationID: UUID().uuidString,
                    generationMetaJson: try SQLiteRecordCoding.json(["titleError": error]), captureState: "completed",
                    createdAt: now,
                    updatedAt: now)
                try log.insert(db)
            }
        }
    }
    public func deleteDialog(_ id: String) throws {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM assistant_conversations WHERE id=? AND archived_at IS NOT NULL", arguments: [key])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
        }
    }
    static func requireOpenAssistantConversation(_ key: Int64, db: Database) throws {
        guard
            try Double.fetchOne(db, sql: "SELECT archived_at FROM assistant_conversations WHERE id=?", arguments: [key])
                == nil
        else { throw RecordStorageError.conflict }
    }

}

extension SQLiteAssistantConversationRepository {
    public func saveAuxiliaryRequest(dialog id: String, request: AssistantModelRequest) throws {
        let owner = try BusinessRecordID.number(id, kind: .dialog)
        try database.write { db in
            let now = Date().timeIntervalSince1970
            let detail = try SQLiteRecordCoding.payload(JSONEncoder().encode(request))
            let metadata = try SQLiteRecordCoding.json(
                detail.filter { SQLiteModelRequestLogRepository.generationKeys.contains($0.key) })
            if request.state == .generating {
                var log = ModelRequestLogRow(
                    assistantConversationID: owner, invocationID: request.id,
                    requestBody: Data((request.requestParametersJSON ?? request.requestJSON).utf8),
                    generationMetaJson: metadata, createdAt: now, updatedAt: now)
                try log.insert(db, onConflict: .ignore)
            } else {
                try db.execute(
                    sql:
                        "UPDATE model_request_log SET response_body=CASE WHEN capture_format='local' THEN ? ELSE response_body END,generation_meta_json=?,capture_state=CASE WHEN capture_format='local' THEN ? ELSE capture_state END,completed_at=COALESCE(completed_at,?),updated_at=? WHERE invocation_id=? AND assistant_conversation_id=?",
                    arguments: [
                        Data((request.responseEventsJSON ?? request.response).utf8), metadata,
                        request.state == .completed ? "completed" : "partial", now, now, request.id, owner,
                    ])
            }
        }
    }
}
