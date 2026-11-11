import Foundation
internal import GRDB
import StorageChat
import StorageCore

extension SQLiteWriterMessageRepository {
    static func ensureMessage(
        owner: Owner, client: String, input: String, position: UInt64, date: Date, invocation: Bool,
        db: Database
    ) throws -> Int64 {
        guard position <= Int64.max else { throw RecordStorageError.invalidRecord }
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
            if invocation, try SQLiteRecordCoding.object(existing["assistant_response_json"])["id"] == nil {
                try db.execute(
                    sql: "UPDATE \(owner.table) SET assistant_response_json=? WHERE id=?",
                    arguments: [try SQLiteRecordCoding.json(["id": client]), key])
                try SQLiteModelRequestLogRepository.initializeLog(
                    agent: "writer", message: key, invocation: client, db: db)
            }
            return key
        }

        guard owner.request else { throw RecordStorageError.invalidRecord }
        guard
            let root = try Row.fetchOne(
                db, sql: "SELECT * FROM writer_executions WHERE id=?", arguments: [owner.key])
        else { throw RecordStorageError.missingRecord }
        let key = try SQLiteRecordCoding.allocateMessage(db)
        let cause = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM writer_messages WHERE delegation_id=? AND root_input_key=? ORDER BY id DESC LIMIT 1",
            arguments: [owner.key, input])
        let response = invocation ? try SQLiteRecordCoding.json(["id": client]) : "{}"
        let now = date.timeIntervalSince1970
        try db.execute(
            sql:
                "INSERT INTO writer_messages(id,delegation_id,workspace_id,request_message_id,input_key,root_input_key,position,input_kind,created_at,updated_at,caused_by_message_id,assistant_response_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            arguments: [
                key, owner.key, root["selected_workspace_id"] as Int64?, root["request_message_id"] as String, client,
                input, key, cause == nil ? "user" : "react", now, now, cause, response,
            ])
        if let workspace: Int64 = root["selected_workspace_id"] {
            try db.execute(
                sql: "UPDATE writer_workspaces SET updated_at=MAX(updated_at,?) WHERE id=?",
                arguments: [now, workspace])
        }
        if invocation {
            try SQLiteModelRequestLogRepository.initializeLog(agent: "writer", message: key, invocation: client, db: db)
        }
        return key
    }
    public func beginMessage(ownerID id: String, identity: WriterMessageIdentity) throws -> String {
        try database.write { db in
            let owner = try Self.owner(id, db: db)
            let key = try Self.ensureMessage(
                owner: owner, client: identity.clientID, input: identity.inputID,
                position: identity.order, date: identity.date, invocation: identity.kind != "input", db: db)
            return SQLiteRecordKey.id(identity.kind == "input" ? .message : .request, key)
        }
    }
    static func saveMessage(_ value: WriterMessageRecord, owner: Owner, db: Database) throws -> WriterMessageReference {
        let key = try ensureMessage(
            owner: owner, client: value.clientID, input: value.inputID, position: value.order,
            date: value.date, invocation: value.kind != "input", db: db)
        let now = Date().timeIntervalSince1970
        if value.role == "user" {
            let existing =
                try String.fetchOne(
                    db,
                    sql: "SELECT user_input_json FROM \(owner.table) WHERE id=?", arguments: [key]) ?? "{}"
            var input = try SQLiteRecordCoding.object(existing)
            input["text"] = value.body
            if value.kind == "input" {
                let detail = try SQLiteRecordCoding.payload(value.detail)
                input["awaitingModel"] = detail["awaitingModel"]
                input["executionError"] = detail["executionError"]
                for result in detail["generationRounds"] as? [[String: Any]] ?? [] {
                    guard let invocation = result["id"] as? String else { throw RecordStorageError.invalidRecord }

                    try saveWriterRoundResult(result, ownerID: owner.key, invocation: invocation, db: db)

                }
            }

            try db.execute(
                sql:
                    "UPDATE \(owner.table) SET user_input_json=?,state=CASE WHEN json_extract(assistant_response_json,'$.id') IS NULL THEN ? ELSE state END,updated_at=? WHERE id=?",
                arguments: [
                    try SQLiteRecordCoding.json(input),
                    value.kind == "input"
                        ? (try SQLiteRecordCoding.payload(value.detail)["state"] as? String ?? value.state)
                        : value.state, now, key,
                ])

        } else {
            var detail = try SQLiteRecordCoding.payload(value.detail)
            let meta = detail.filter {
                SQLiteModelRequestLogRepository.generationKeys.contains($0.key)
                    || ["error", "failureDiagnostic"].contains($0.key)
            }
            try SQLiteModelRequestLogRepository.saveGenerationMetadata(
                meta, invocation: value.clientID, at: now, db: db)
            if let messages = detail.removeValue(forKey: "inputMessages") {
                try db.execute(
                    sql:
                        "UPDATE \(owner.table) SET user_input_json=json_set(user_input_json,'$.messages',json(?)) WHERE id=?",
                    arguments: [try SQLiteRecordCoding.json(messages), key])
            }
            let tools = detail.removeValue(forKey: "toolCalls") ?? []
            var decision = detail.removeValue(forKey: "decisionMetadata") as? [String: Any] ?? [:]
            for name in SQLiteModelRequestLogRepository.generationKeys.union([
                "messageID", "inputMessageID", "historyOrder", "date", "id", "input", "state",
            ]) { detail[name] = nil }
            detail["id"] = value.clientID
            detail["text"] = value.body
            let response = try SQLiteRecordCoding.json(detail)
            try db.execute(
                sql:
                    "UPDATE \(owner.table) SET assistant_response_json=?,tool_calls_json=?,state=?,updated_at=?,completed_at=? WHERE id=?",
                arguments: [
                    response, try SQLiteRecordCoding.json(tools), value.state, now,
                    value.state == "generating" ? nil : now, key,
                ])

            decision["targetPath"] = (detail["producerMetadata"] as? [String: Any])?["path"]
            try saveWriterDetails(decision, message: key, db: db)

        }
        return WriterMessageReference(
            id: SQLiteRecordKey.id(value.role == "user" && value.kind == "input" ? .message : .request, key),
            clientID: value.clientID, role: value.role)
    }
}
