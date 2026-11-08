import Foundation
internal import GRDB
import StorageChat
import StorageCore

public final class SQLiteAssistantMessageRepository: AssistantMessageRepository {
    public var storageScope: UUID { database.storageScope }
    let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }
    struct Owner {
        let key: Int64
        var table: String { "assistant_messages" }
        var column: String { "conversation_id" }
        var resultsColumn: String { "action_results_json" }
        var id: String { "dialog_\(key)" }
    }
    static func owner(_ id: String, db: Database) throws -> Owner {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        guard
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assistant_conversations WHERE id=?", arguments: [key]) == 1
        else { throw RecordStorageError.missingRecord }
        return Owner(key: key)
    }
    static func locate(_ key: Int64, db: Database) throws -> (Owner, Row) {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM assistant_messages WHERE id=?", arguments: [key]),
            let owner: Int64 = row["conversation_id"]
        else { throw RecordStorageError.missingRecord }
        return (Owner(key: owner), row)
    }
    internal func recoverInFlight() throws { try database.write { try Self.recoverAssistantMessages($0) } }
}

extension SQLiteAssistantMessageRepository {
    static func saveAssistantDetails(_ decision: [String: Any], message: Int64, changed: Bool, db: Database) throws {
        if !decision.isEmpty {
            var selection = decision
            let skills = selection.removeValue(forKey: "skills") ?? [:]
            let catalog = try SQLiteRecordCoding.object(selection.removeValue(forKey: "catalogJSON") as? String ?? "{}")
            try db.execute(
                sql:
                    "UPDATE assistant_messages SET decision_json=?,skills_json=?,action_catalog_json=?,tool_catalog_json=? WHERE id=?",
                arguments: [
                    try SQLiteRecordCoding.json(selection), try SQLiteRecordCoding.json(skills),
                    try SQLiteRecordCoding.json(catalog["actions"] ?? []),
                    try SQLiteRecordCoding.json(catalog["tools"] ?? []), message,
                ])
        }
        if changed { try SQLiteAssistantTaskRepository.invalidateAssistantMessageSummary(message, db: db) }
    }
    static func recoverAssistantMessages(_ db: Database) throws {
        try db.execute(
            sql:
                "UPDATE assistant_messages SET state='interrupted',completed_at=?,updated_at=? WHERE state='generating'",
            arguments: [Date().timeIntervalSince1970, Date().timeIntervalSince1970])
    }

    static func validateAssistantMessageTask(_ id: String?, conversation: Int64, db: Database) throws -> Int64? {
        let key = try id.map { try BusinessRecordID.number($0, kind: .task) }
        if let key {
            guard
                try Int64.fetchOne(db, sql: "SELECT conversation_id FROM assistant_tasks WHERE id=?", arguments: [key])
                    == conversation
            else { throw RecordStorageError.conflict }
        }
        return key
    }
    static func bindAssistantMessageTask(_ task: Int64, message: Int64, previous: Int64?, db: Database) throws {
        guard previous == nil || previous == task else { throw RecordStorageError.conflict }
        if previous == nil {
            try db.execute(sql: "UPDATE assistant_messages SET task_id=? WHERE id=?", arguments: [task, message])
            try SQLiteAssistantTaskRepository.invalidateAssistantSummary(task, db: db)
        }
    }
    static func associateAssistantMessage(_ message: Int64, input: String, db: Database) throws {
        try db.execute(
            sql:
                "UPDATE assistant_messages SET source_agent_message_id=(SELECT id FROM agent_messages WHERE id=? AND receiver_agent_id='assistant'),input_kind=CASE WHEN EXISTS(SELECT 1 FROM agent_messages WHERE id=? AND receiver_agent_id='assistant') THEN 'agent' ELSE input_kind END WHERE id=?",
            arguments: [input, input, message])
    }
    static func saveAssistantRoundResult(_ result: [String: Any], conversation: Int64, invocation: String, db: Database)
        throws
    {
        let encoded = try SQLiteRecordCoding.json([result])
        try SQLiteAssistantTaskRepository.invalidateAssistantResultSummary(
            conversation: conversation, invocation: invocation, result: encoded, db: db)
        try db.execute(
            sql:
                "UPDATE assistant_messages SET action_results_json=? WHERE conversation_id=? AND json_extract(assistant_response_json,'$.id')=?",
            arguments: [encoded, conversation, invocation])
    }

    static func assistantMessageDecision(_ row: Row) throws -> AssistantDecisionMetadata? {
        var selection = try SQLiteRecordCoding.object(row["decision_json"])
        selection["skills"] = try JSONSerialization.jsonObject(with: Data((row["skills_json"] as String).utf8))
        selection["catalogJSON"] = try SQLiteRecordCoding.json([
            "actions": JSONSerialization.jsonObject(with: Data((row["action_catalog_json"] as String).utf8)),
            "tools": JSONSerialization.jsonObject(with: Data((row["tool_catalog_json"] as String).utf8)),
        ])
        if selection["mode"] != nil {
            return try JSONDecoder().decode(
                AssistantDecisionMetadata.self, from: Data(SQLiteRecordCoding.json(selection).utf8))
        }
        return nil
    }

    static func assistantPreviewScope(task: Bool) -> (join: String, filter: String, taskColumn: String) {
        let filter =
            task
            ? " AND m.task_id=?"
            : " AND (t.id IS NULL OR NOT (\(SQLiteAssistantTaskRepository.validSummary)) OR m.id=(SELECT id FROM assistant_messages WHERE task_id=t.id ORDER BY position,id LIMIT 1))"
        return (" LEFT JOIN assistant_tasks t ON t.id=m.task_id", filter, "m.task_id")
    }

}

extension SQLiteAssistantMessageRepository {
    @discardableResult public func save(
        dialog id: String, revision: UInt64, messages: [AssistantMessageRecord], summaries: [TaskCompressionRecord]
    ) throws -> [AssistantMessageReference] {
        guard revision <= Int64.max else { throw RecordStorageError.invalidRecord }
        return try database.write { db in
            let owner = try Self.owner(id, db: db)
            let references = try messages.map { try Self.saveMessage($0, owner: owner, db: db) }
            try SQLiteAssistantTaskRepository.saveSummaries(summaries, conversation: owner.key, db: db)
            try db.execute(
                sql: "UPDATE assistant_conversations SET revision=MAX(revision+1,?) WHERE id=?",
                arguments: [Int64(revision), owner.key])
            return references
        }
    }
}
