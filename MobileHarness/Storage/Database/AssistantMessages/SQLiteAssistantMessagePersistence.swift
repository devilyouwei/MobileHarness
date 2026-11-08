import Foundation
internal import GRDB
import StorageChat
import StorageCore

extension SQLiteAssistantMessageRepository {
    static func ensureMessage(
        owner: Owner, client: String, input: String, task: String?, position: UInt64, date: Date, invocation: Bool,
        db: Database
    ) throws -> Int64 {
        guard position <= Int64.max else { throw RecordStorageError.invalidRecord }
        let taskKey =
            try validateAssistantMessageTask(task, conversation: owner.key, db: db)
        var existing = try Row.fetchOne(
            db,
            sql:
                "SELECT * FROM \(owner.table) WHERE \(owner.column)=? AND (input_key=? OR json_extract(assistant_response_json,'$.id')=?)",
            arguments: [owner.key, client, client])
        if existing == nil && invocation {
            existing = try Row.fetchOne(
                db,
                sql:
                    "SELECT * FROM \(owner.table) WHERE \(owner.column)=? AND input_key=? AND assistant_response_json='{}'",
                arguments: [owner.key, input])
        }
        if let existing {
            guard existing["root_input_key"] as String == input else { throw RecordStorageError.conflict }
            let key: Int64 = existing["id"]
            if let taskKey {
                try bindAssistantMessageTask(taskKey, message: key, previous: existing["task_id"], db: db)
            }
            if invocation, try SQLiteRecordCoding.object(existing["assistant_response_json"])["id"] == nil {
                try db.execute(
                    sql: "UPDATE \(owner.table) SET assistant_response_json=? WHERE id=?",
                    arguments: [try SQLiteRecordCoding.json(["id": client]), key])
                try SQLiteModelRequestLogRepository.initializeLog(
                    agent: "assistant", message: key, invocation: client, db: db)
            }
            return key
        }
        try SQLiteAssistantConversationRepository.requireOpenAssistantConversation(owner.key, db: db)
        let key = try SQLiteRecordCoding.allocateMessage(db)
        let cause = try Int64.fetchOne(
            db,
            sql:
                "SELECT id FROM \(owner.table) WHERE \(owner.column)=? AND root_input_key=? ORDER BY position DESC,id DESC LIMIT 1",
            arguments: [owner.key, input])
        let response = invocation ? try SQLiteRecordCoding.json(["id": client]) : "{}"
        let now = date.timeIntervalSince1970
        try db.execute(
            sql:
                "INSERT INTO \(owner.table)(id,\(owner.column),input_key,root_input_key,position,input_kind,created_at,updated_at,caused_by_message_id,assistant_response_json) VALUES(?,?,?,?,?,?,?,?,?,?)",
            arguments: [
                key, owner.key, client, input, Int64(position), cause == nil ? "user" : "react", now, now, cause,
                response,
            ])

        try associateAssistantMessage(key, input: input, db: db)
        if let taskKey { try bindAssistantMessageTask(taskKey, message: key, previous: nil, db: db) }

        if invocation {
            try SQLiteModelRequestLogRepository.initializeLog(
                agent: "assistant", message: key, invocation: client, db: db)
        }
        return key
    }
    public func beginMessage(dialog id: String, identity: AssistantMessageIdentity) throws -> String {
        try database.write { db in
            let owner = try Self.owner(id, db: db)
            let key = try Self.ensureMessage(
                owner: owner, client: identity.clientID, input: identity.inputID, task: identity.taskID,
                position: identity.order, date: identity.date, invocation: identity.kind != "input", db: db)
            return SQLiteRecordKey.id(identity.kind == "input" ? .message : .request, key)
        }
    }
    static func saveMessage(_ value: AssistantMessageRecord, owner: Owner, db: Database) throws
        -> AssistantMessageReference
    {
        let key = try ensureMessage(
            owner: owner, client: value.clientID, input: value.inputID, task: value.taskID, position: value.order,
            date: value.date, invocation: value.kind != "input", db: db)
        let now = Date().timeIntervalSince1970
        if value.role == "user" {
            var input: [String: Any] = ["text": value.body]
            if value.kind == "input" {
                let detail = try SQLiteRecordCoding.payload(value.detail)
                input["awaitingModel"] = detail["awaitingModel"]
                input["executionError"] = detail["executionError"]
                if let definitions = detail["toolDefinitions"] {
                    try db.execute(
                        sql: "UPDATE \(owner.table) SET tool_catalog_json=? WHERE id=?",
                        arguments: [try SQLiteRecordCoding.json(definitions), key])
                }
                for result in detail["generationRounds"] as? [[String: Any]] ?? [] {
                    guard let invocation = result["id"] as? String else { throw RecordStorageError.invalidRecord }

                    try saveAssistantRoundResult(result, conversation: owner.key, invocation: invocation, db: db)

                }
            }

            try SQLiteAssistantTaskRepository.invalidateAssistantInputSummary(
                message: key, input: try SQLiteRecordCoding.json(input), db: db)

            try db.execute(
                sql:
                    "UPDATE \(owner.table) SET user_input_json=?,state=CASE WHEN json_extract(assistant_response_json,'$.id') IS NULL THEN ? ELSE state END,updated_at=? WHERE id=?",
                arguments: [
                    try SQLiteRecordCoding.json(input),
                    value.kind == "input"
                        ? (try SQLiteRecordCoding.payload(value.detail)["state"] as? String ?? value.state)
                        : value.state, now, key,
                ])
            if let source = try String.fetchOne(
                db, sql: "SELECT source_agent_message_id FROM assistant_messages WHERE id=?", arguments: [key])
            {
                try SQLiteAgentMessageRepository.consumeSource(source, at: now, db: db)
            }
        } else {
            var detail = try SQLiteRecordCoding.payload(value.detail)
            let meta = detail.filter {
                SQLiteModelRequestLogRepository.generationKeys.contains($0.key)
                    || ["error", "failureDiagnostic"].contains($0.key)
            }
            try SQLiteModelRequestLogRepository.saveGenerationMetadata(
                meta, invocation: value.clientID, at: now, db: db)
            let tools = detail.removeValue(forKey: "toolCalls") ?? []
            var decision = detail.removeValue(forKey: "decisionMetadata") as? [String: Any] ?? [:]
            for name in SQLiteModelRequestLogRepository.generationKeys.union([
                "messageID", "inputMessageID", "historyTaskID", "historyOrder", "date", "id", "input", "state",
            ]) { detail[name] = nil }
            detail["id"] = value.clientID
            detail["text"] = value.body
            let response = try SQLiteRecordCoding.json(detail)
            let old = try Row.fetchOne(
                db, sql: "SELECT assistant_response_json,tool_calls_json FROM \(owner.table) WHERE id=?",
                arguments: [key])
            let toolsJSON = try SQLiteRecordCoding.json(tools)
            try db.execute(
                sql:
                    "UPDATE \(owner.table) SET assistant_response_json=?,tool_calls_json=?,state=?,updated_at=?,completed_at=? WHERE id=?",
                arguments: [
                    response, try SQLiteRecordCoding.json(tools), value.state, now,
                    value.state == "generating" ? nil : now, key,
                ])

            try saveAssistantDetails(
                decision, message: key,
                changed: (old?["assistant_response_json"] as String?) != response
                    || (old?["tool_calls_json"] as String?) != toolsJSON, db: db)

        }
        return AssistantMessageReference(
            id: SQLiteRecordKey.id(value.role == "user" && value.kind == "input" ? .message : .request, key),
            clientID: value.clientID, role: value.role)
    }
}
