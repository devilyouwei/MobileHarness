import Foundation
internal import GRDB
import StorageChat
import StorageCore

extension SQLiteAssistantTaskRepository {
    static func saveSummaries(_ summaries: [TaskCompressionRecord], conversation: Int64, db: Database) throws {
        for summary in summaries {
            let key = try BusinessRecordID.number(summary.id, kind: .task)
            let sources = try Self.taskSources(key, db: db)
            guard Set(summary.sources) == Set(sources.map(\.requestID)) else { throw RecordStorageError.conflict }
            try db.execute(
                sql:
                    "UPDATE assistant_tasks SET description=?,state=?,summary=?,failure_json=?,ended_at=?,summary_revision=source_revision WHERE id=? AND conversation_id=?",
                arguments: [
                    summary.goal, summary.status, summary.summary,
                    try summary.failure.map { try SQLiteRecordCoding.json(["message": $0]) },
                    summary.finishedAt.timeIntervalSince1970,
                    key, conversation,
                ])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
        }
    }
    static func taskSources(_ key: Int64, db: Database) throws -> [TaskSourceRecord] {
        try Row.fetchAll(
            db,
            sql:
                "SELECT root_input_key,json_extract(assistant_response_json,'$.id') AS invocation,position FROM assistant_messages WHERE task_id=? AND json_extract(assistant_response_json,'$.id') IS NOT NULL ORDER BY position,id",
            arguments: [key]
        ).map {
            .init(inputID: $0["root_input_key"], requestID: $0["invocation"], position: UInt64($0["position"] as Int64))
        }
    }
    public func taskSources(_ id: String) throws -> [TaskSourceRecord] {
        try database.read { try Self.taskSources(BusinessRecordID.number(id, kind: .task), db: $0) }
    }
    public func compressionData(dialog id: String, taskIDs: [String]? = nil) throws -> [Data] {
        try database.read { db in
            let conversation = try BusinessRecordID.number(id, kind: .dialog)
            let keys = try taskIDs.map { try Set($0.map { try BusinessRecordID.number($0, kind: .task) }) }
            return try Row.fetchAll(
                db,
                sql:
                    "SELECT t.* FROM assistant_tasks t WHERE conversation_id=? AND \(Self.validSummary) ORDER BY started_at,id",
                arguments: [conversation]
            ).compactMap { row in
                let key: Int64 = row["id"]
                guard keys?.contains(key) ?? true else { return nil }
                let sources = try Self.taskSources(key, db: db)
                guard !sources.isEmpty, let ended: Double = row["ended_at"],
                    let state = AssistantRecord.State(rawValue: row["state"])
                else { return nil }
                let failure = try (row["failure_json"] as String?).flatMap {
                    try SQLiteRecordCoding.object($0)["message"] as? String
                }
                let value = AssistantTaskCompression(
                    taskID: "task_\(key)", goal: row["description"], status: state, reportedSummary: row["summary"],
                    failure: failure, completedAt: Date(timeIntervalSince1970: ended),
                    sources: sources.map { .init(inputID: $0.inputID, requestID: $0.requestID) })
                return try JSONEncoder().encode(value)
            }
        }
    }
    static func invalidateAssistantSummary(_ task: Int64, db: Database) throws {
        try db.execute(
            sql: "UPDATE assistant_tasks SET source_revision=source_revision+1 WHERE id=?", arguments: [task])
    }

    static let validSummary =
        "COALESCE(t.summary_revision=t.source_revision,0) AND COALESCE(t.summary,'')!='' AND t.state NOT IN ('running','finishing','closing','cleanup_failed')"

    static func invalidateAssistantMessageSummary(_ message: Int64, db: Database) throws {
        try db.execute(
            sql:
                "UPDATE assistant_tasks SET source_revision=source_revision+1 WHERE id=(SELECT task_id FROM assistant_messages WHERE id=?)",
            arguments: [message])
    }
    static func invalidateAssistantResultSummary(conversation: Int64, invocation: String, result: String, db: Database)
        throws
    {
        try db.execute(
            sql:
                "UPDATE assistant_tasks SET source_revision=source_revision+1 WHERE id IN (SELECT task_id FROM assistant_messages WHERE conversation_id=? AND json_extract(assistant_response_json,'$.id')=? AND action_results_json!=?)",
            arguments: [conversation, invocation, result])
    }
    static func invalidateAssistantInputSummary(message: Int64, input: String, db: Database) throws {
        try db.execute(
            sql:
                "UPDATE assistant_tasks SET source_revision=source_revision+1 WHERE id=(SELECT task_id FROM assistant_messages WHERE id=? AND user_input_json!=?)",
            arguments: [message, input])
    }

}
