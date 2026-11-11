import Foundation
internal import GRDB
import StorageChat
import StorageCore

extension SQLiteAssistantMessageRepository {
    static func records(_ row: Row, owner: Owner, db: Database) throws -> [AssistantMessageRecord] {
        let key: Int64 = row["id"]
        let root: String = row["root_input_key"]
        let original =
            try Row.fetchOne(
                db, sql: "SELECT * FROM \(owner.table) WHERE \(owner.column)=? AND input_key=?",
                arguments: [owner.key, root]) ?? row
        let originalInput = try SQLiteRecordCoding.object(original["user_input_json"])
        let input = try SQLiteRecordCoding.object(row["user_input_json"])
        let response = try SQLiteRecordCoding.object(row["assistant_response_json"])
        let originalResponse = try SQLiteRecordCoding.object(original["assistant_response_json"])
        let originalMeta = try originalResponse["id"].flatMap { value -> String? in
            guard let id = value as? String else { return nil }
            return try SQLiteModelRequestLogRepository.generationMetadata(id, db: db)
        }
        let parameters = try SQLiteRecordCoding.object(originalMeta ?? "{}")
        var turn = AssistantRecord(
            id: root, date: Date(timeIntervalSince1970: original["created_at"]),
            user: originalInput["text"] as? String ?? "", request: [], model: parameters["model"] as? String ?? "",
            maximumOutputTokens: parameters["maximumOutputTokens"] as? Int,
            temperature: parameters["temperature"] as? Double ?? 0)
        turn.historyOrder = UInt64(original["position"] as Int64)
        if let coordination = originalInput["coordination"] {
            turn.coordination = try JSONDecoder().decode(
                AssistantInputCoordination.self,
                from: Data(SQLiteRecordCoding.json(coordination).utf8))
        }
        turn.awaitingModel = originalInput["awaitingModel"] as? Bool ?? false
        turn.executionError = originalInput["executionError"] as? String
        turn.error = originalInput["error"] as? String
        turn.finishReason = originalInput["finishReason"] as? String
        let inputState: String =
            originalResponse["id"] == nil
            ? original["state"] : (originalInput["state"] as? String ?? original["state"])
        turn.state = AssistantRecord.State(rawValue: inputState) ?? .interrupted
        let rounds = try String.fetchAll(
            db,
            sql:
                "SELECT \(owner.resultsColumn) FROM \(owner.table) WHERE \(owner.column)=? AND root_input_key=? ORDER BY position,id",
            arguments: [owner.key, root])
        turn.generationRounds = try rounds.flatMap {
            let entries = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]] ?? []
            return try entries.filter { $0["id"] != nil && $0["resultsJSON"] != nil }.map {
                try JSONDecoder().decode(ModelGenerationRound.self, from: Data(SQLiteRecordCoding.json($0).utf8))
            }
        }
        let definitions = try JSONSerialization.jsonObject(with: Data((original["tool_catalog_json"] as String).utf8))
        turn.toolDefinitions = definitions as? [String]
        var result: [AssistantMessageRecord] =
            originalInput.isEmpty
            ? []
            : [
                AssistantMessageRecord(
                    clientID: root, inputID: root, role: "user", kind: "input", order: turn.historyOrder,
                    date: turn.date,
                    body: turn.user, state: "completed", detail: try JSONEncoder().encode(turn),
                    id: SQLiteRecordKey.id(.message, original["id"]))
            ]
        guard let invocation = response["id"] as? String else { return result }
        let task: Int64? = row["task_id"]
        var request = AssistantModelRequest(
            id: invocation, input: input["requestText"] as? String ?? input["text"] as? String ?? turn.user,
            requestJSON: "[]",
            historyTaskID: task.map { "task_\($0)" }, date: Date(timeIntervalSince1970: row["created_at"]))
        request.historyOrder = UInt64(row["position"] as Int64)
        request.state = AssistantRecord.State(rawValue: row["state"]) ?? .interrupted
        request.response = response["text"] as? String ?? ""
        request.producerMetadata = response["producerMetadata"] as? [String: String]
        request.toolCalls = try JSONDecoder().decode(
            [ModelToolCall].self, from: Data((row["tool_calls_json"] as String).utf8))
        request.decisionMetadata =
            try assistantMessageDecision(row)
        if let meta = try SQLiteModelRequestLogRepository.generationMetadata(invocation, db: db) {
            let metadata = try SQLiteRecordCoding.object(meta)
            var encoded = try SQLiteRecordCoding.payload(JSONEncoder().encode(request))
            for (name, value) in metadata
            where SQLiteModelRequestLogRepository.generationKeys.contains(name)
                && !["request", "requestJSON", "requestParametersJSON", "responseEventsJSON"].contains(name)
            { encoded[name] = value }
            request = try JSONDecoder().decode(
                AssistantModelRequest.self, from: Data(SQLiteRecordCoding.json(encoded).utf8))
        }
        if row["input_kind"] as String == "react" {
            result.append(
                AssistantMessageRecord(
                    clientID: invocation, inputID: root, role: "user", kind: "observation", order: request.historyOrder,
                    date: request.date, body: request.input, state: "completed", taskID: request.historyTaskID,
                    detail: Data(), id: SQLiteRecordKey.id(.message, key)))
        }
        result.append(
            AssistantMessageRecord(
                clientID: invocation, inputID: root, role: "assistant", kind: "response", order: request.historyOrder,
                date: request.date, body: request.response, state: request.state.rawValue,
                taskID: request.historyTaskID, detail: try JSONEncoder().encode(request),
                id: SQLiteRecordKey.id(.request, key)))
        return result
    }
    public func messagePage(dialog id: String, after: Int64? = nil, limit: Int = 50) throws -> AssistantMessagePage {
        guard (1...50).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            let owner = try Self.owner(id, db: db)
            var position: Int64 = -1
            if let after {
                guard
                    let found = try Int64.fetchOne(
                        db, sql: "SELECT position FROM \(owner.table) WHERE id=? AND \(owner.column)=?",
                        arguments: [after, owner.key])
                else { throw RecordStorageError.missingRecord }
                position = found
            }
            let rows = try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM \(owner.table) WHERE \(owner.column)=? AND (position,id)>(?,?) ORDER BY position,id LIMIT ?",
                arguments: [owner.key, position, after ?? 0, limit + 1])
            let page = Array(rows.prefix(limit))
            return AssistantMessagePage(
                records: try Self.uniqueRecords(page.flatMap { try Self.records($0, owner: owner, db: db) }),
                next: rows.count > limit ? page.last?["id"] : nil)
        }
    }
    static func uniqueRecords(_ values: [AssistantMessageRecord]) -> [AssistantMessageRecord] {
        var roots: Set<String> = []
        return values.filter { $0.kind != "input" || roots.insert($0.clientID).inserted }
    }
    public func messages(dialog id: String, after: Int64? = nil, limit: Int = 50) throws -> [AssistantMessageRecord] {
        try messagePage(dialog: id, after: after, limit: limit).records
    }
    public func messageEvidence(_ id: String) throws -> [AssistantMessageRecord] {
        try database.read { db in
            let (owner, row) = try Self.locate(SQLiteRecordCoding.key(id), db: db)
            return try Self.records(row, owner: owner, db: db)
        }
    }
    public func dialogForMessage(_ id: String) throws -> String {
        try database.read { try Self.locate(SQLiteRecordCoding.key(id), db: $0).0.id }
    }
    public func dialogForInput(_ input: String) throws -> String? {
        try database.read { db in
            var owners: Set<String> = []
            for (table, column, _) in [
                ("assistant_messages", "conversation_id", "assistant")
            ] {
                for key in try Int64.fetchAll(
                    db, sql: "SELECT DISTINCT \(column) FROM \(table) WHERE root_input_key=? AND \(column) IS NOT NULL",
                    arguments: [input])
                { owners.insert(Owner(key: key).id) }
            }
            guard owners.count <= 1 else { throw RecordStorageError.conflict }
            return owners.first
        }
    }
    public func inputRows(_ input: String, dialog id: String) throws -> [AssistantMessageRecord] {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            return try Row.fetchAll(
                db,
                sql: "SELECT * FROM \(owner.table) WHERE \(owner.column)=? AND root_input_key=? ORDER BY position,id",
                arguments: [owner.key, input]
            ).flatMap { try Self.records($0, owner: owner, db: db) }
        }
    }
    public func unfinishedUserMessages(dialog id: String) throws -> [AssistantMessageRecord] {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            return try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM \(owner.table) WHERE \(owner.column)=? AND assistant_response_json='{}' ORDER BY position,id",
                arguments: [owner.key]
            ).flatMap { try Self.records($0, owner: owner, db: db) }
        }
    }
    static func previewSQL(owner: Owner, task: Bool) -> String {
        let scope = assistantPreviewScope(task: task)
        return
            "SELECT m.id,m.input_key,m.root_input_key,m.position,m.created_at,m.state,m.input_kind,json_extract(m.user_input_json,'$.coordination') AS coordination,substr(COALESCE(json_extract(m.user_input_json,'$.requestText'),json_extract(m.user_input_json,'$.text')),1,240) AS input_text,substr(json_extract(m.assistant_response_json,'$.text'),1,240) AS response_text,json_extract(m.assistant_response_json,'$.id') AS invocation,\(scope.taskColumn),(SELECT COALESCE(json_group_array(json_object('id',json_extract(c.value,'$.id'),'providerID',json_extract(c.value,'$.providerID'),'name',json_extract(c.value,'$.name'),'argumentsJSON',substr(CASE WHEN json_valid(json_extract(c.value,'$.argumentsJSON')) THEN (SELECT json_group_object(a.key,substr(CAST(a.value AS TEXT),1,512)) FROM json_each(json_extract(c.value,'$.argumentsJSON')) a WHERE a.key IN ('command','path','title','description','text','reason','agent_id')) ELSE '{}' END,1),'state',json_extract(c.value,'$.state'))),'[]') FROM json_each(m.tool_calls_json) c) AS tool_calls_json,json_extract(m.assistant_response_json,'$.producerMetadata') AS producer_metadata FROM \(owner.table) m\(scope.join) WHERE m.\(owner.column)=? AND json_extract(m.assistant_response_json,'$.id') IS NOT NULL AND m.position>?\(scope.filter) ORDER BY m.position,m.id LIMIT ? OFFSET ?"
    }
    public func previews(
        dialog id: String, after: UInt64 = 0, taskID: String? = nil, limit: Int = HistoryPaging.pageSize,
        offset: Int = 0
    ) throws -> [AssistantMessagePreview] {
        guard after <= Int64.max, (1...50).contains(limit), offset >= 0 else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            let owner = try Self.owner(id, db: db)

            let task = try taskID.map { try BusinessRecordID.number($0, kind: .task) }
            let args = StatementArguments(
                [owner.key, Int64(after)] + (task.map { [$0] } ?? []) + [Int64(limit), Int64(offset)])
            let scope =
                Self.assistantPreviewScope(task: task != nil)
            let preceding =
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM \(owner.table) m\(scope.join) WHERE m.\(owner.column)=? AND json_extract(m.assistant_response_json,'$.id') IS NOT NULL AND m.position>0 AND m.position<=?\(scope.filter)",
                    arguments: StatementArguments([owner.key, Int64(after)] + (task.map { [$0] } ?? []))) ?? 0
            return try Row.fetchAll(db, sql: Self.previewSQL(owner: owner, task: task != nil), arguments: args)
                .enumerated().map { index, row in
                    let task: Int64? = row["task_id"]
                    let invocation: String? = row["invocation"]
                    var value = AssistantMessagePreview(
                        id: SQLiteRecordKey.id(invocation == nil ? .message : .request, row["id"]),
                        clientID: invocation ?? row["input_key"], inputID: row["root_input_key"],
                        input: row["input_text"] as String? ?? "", response: row["response_text"] as String? ?? "",
                        date: Date(timeIntervalSince1970: row["created_at"]),
                        position: UInt64(row["position"] as Int64), state: row["state"],
                        taskID: task.map { "task_\($0)" }, isObservation: row["input_kind"] as String == "react",
                        isInput: invocation == nil)
                    value.ordinal = preceding + offset + index + 1
                    if let coordination: String = row["coordination"] {
                        value.coordination = try JSONDecoder().decode(
                            AssistantInputCoordination.self, from: Data(coordination.utf8))
                    }
                    let calls = try JSONDecoder().decode(
                        [ModelToolCall].self, from: Data((row["tool_calls_json"] as String).utf8))
                    value.toolCalls = calls.map {
                        .init(name: $0.name, argumentsJSON: $0.argumentsJSON, state: $0.state.rawValue)
                    }
                    if let metadata: String = row["producer_metadata"] {
                        value.metadata = try JSONDecoder().decode([String: String].self, from: Data(metadata.utf8))
                    }
                    if calls.contains(where: { $0.state == .received }) { value.metadata["toolsPending"] = "true" }
                    return value
                }
        }
    }
    func previewQueryPlan(dialog id: String, after: UInt64, taskID: String? = nil) throws -> [String] {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            let task = try taskID.map { try BusinessRecordID.number($0, kind: .task) }
            return try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN " + Self.previewSQL(owner: owner, task: task != nil),
                arguments: StatementArguments([owner.key, Int64(after)] + (task.map { [$0] } ?? []) + [20, 0])
            ).map { $0["detail"] }
        }
    }
    public func timelineCount(dialog id: String) throws -> Int {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            let sql = Self.previewSQL(owner: owner, task: false)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (\(sql))", arguments: [owner.key, -1, Int64.max, 0])
                ?? 0
        }
    }
    public func latestPreviews(dialog id: String, limit: Int = 10) throws -> [AssistantMessagePreview] {
        try previews(dialog: id, limit: limit, offset: max(0, try timelineCount(dialog: id) - limit))
    }
    public func titleRows(dialog id: String, positions: [Int]) throws -> [AssistantMessagePreview] {
        try positions.flatMap { try previews(dialog: id, limit: 1, offset: $0) }
    }
}
