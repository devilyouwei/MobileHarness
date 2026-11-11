import Foundation
internal import GRDB
import StorageChat
import StorageCore

extension SQLiteWriterMessageRepository {
    static func records(_ row: Row, owner: Owner, db: Database) throws -> [WriterMessageRecord] {
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
        var turn = WriterRecord(
            id: root, date: Date(timeIntervalSince1970: original["created_at"]),
            user: originalInput["text"] as? String ?? "", request: [], model: parameters["model"] as? String ?? "",
            maximumOutputTokens: parameters["maximumOutputTokens"] as? Int,
            temperature: parameters["temperature"] as? Double ?? 0)
        turn.historyOrder = UInt64(original["position"] as Int64)
        turn.awaitingModel = originalInput["awaitingModel"] as? Bool ?? false
        turn.executionError = originalInput["executionError"] as? String
        turn.state = WriterRecord.State(rawValue: original["state"]) ?? .interrupted
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
        var result: [WriterMessageRecord] =
            originalInput.isEmpty
            ? []
            : [
                WriterMessageRecord(
                    clientID: root, inputID: root, role: "user", kind: "input", order: turn.historyOrder,
                    date: turn.date,
                    body: turn.user, state: "completed", detail: try JSONEncoder().encode(turn),
                    id: SQLiteRecordKey.id(.message, original["id"]))
            ]
        guard let invocation = response["id"] as? String else { return result }
        var request = WriterModelRequest(
            id: invocation, input: input["text"] as? String ?? turn.user, requestJSON: "[]",
            date: Date(timeIntervalSince1970: row["created_at"]))
        if let messages = input["messages"] {
            request.inputMessages = try JSONDecoder().decode(
                [WriterInputMessage].self,
                from: Data(SQLiteRecordCoding.json(messages).utf8))
        }
        request.historyOrder = UInt64(row["position"] as Int64)
        request.state = WriterRecord.State(rawValue: row["state"]) ?? .interrupted
        request.response = response["text"] as? String ?? ""
        request.producerMetadata = response["producerMetadata"] as? [String: String]
        request.toolCalls = try JSONDecoder().decode(
            [ModelToolCall].self, from: Data((row["tool_calls_json"] as String).utf8))
        request.decisionMetadata =
            try writerMessageDecision(row)
        if let meta = try SQLiteModelRequestLogRepository.generationMetadata(invocation, db: db) {
            let metadata = try SQLiteRecordCoding.object(meta)
            var encoded = try SQLiteRecordCoding.payload(JSONEncoder().encode(request))
            for (name, value) in metadata
            where SQLiteModelRequestLogRepository.generationKeys.contains(name)
                && !["request", "requestJSON", "requestParametersJSON", "responseEventsJSON"].contains(name)
            { encoded[name] = value }
            request = try JSONDecoder().decode(
                WriterModelRequest.self, from: Data(SQLiteRecordCoding.json(encoded).utf8))
        }
        if row["input_kind"] as String == "react" {
            result.append(
                WriterMessageRecord(
                    clientID: invocation, inputID: root, role: "user", kind: "observation", order: request.historyOrder,
                    date: request.date, body: request.input, state: "completed", detail: Data(),
                    id: SQLiteRecordKey.id(.message, key)))
        }
        result.append(
            WriterMessageRecord(
                clientID: invocation, inputID: root, role: "assistant", kind: "response", order: request.historyOrder,
                date: request.date, body: request.response, state: request.state.rawValue,
                detail: try JSONEncoder().encode(request),
                id: SQLiteRecordKey.id(.request, key)))
        return result
    }
    public func messagePage(ownerID id: String, after: Int64? = nil, limit: Int = 50) throws -> WriterMessagePage {
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
            return WriterMessagePage(
                records: try Self.uniqueRecords(page.flatMap { try Self.records($0, owner: owner, db: db) }),
                next: rows.count > limit ? page.last?["id"] : nil)
        }
    }
    static func uniqueRecords(_ values: [WriterMessageRecord]) -> [WriterMessageRecord] {
        var roots: Set<String> = []
        return values.filter { $0.kind != "input" || roots.insert($0.clientID).inserted }
    }
    public func messages(ownerID id: String, after: Int64? = nil, limit: Int = 50) throws -> [WriterMessageRecord] {
        try messagePage(ownerID: id, after: after, limit: limit).records
    }
    public func messageEvidence(_ id: String) throws -> [WriterMessageRecord] {
        try database.read { db in
            let (owner, row) = try Self.locate(SQLiteRecordCoding.key(id), db: db)
            return try Self.records(row, owner: owner, db: db)
        }
    }
    public func detailContext(_ id: String, toolCallIDs: [String]) throws -> WriterMessageDetailContext {
        let key = try SQLiteRecordCoding.key(id)
        return try database.read { db in
            let (owner, row) = try Self.locate(key, db: db)
            let position: Int64 = row["position"]
            let workspace: Int64? = row["workspace_id"]
            let preceding =
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM writer_messages WHERE \(workspace == nil ? "delegation_id=? AND workspace_id IS NULL" : "workspace_id=?") AND position>0 AND (position,id)<(?,?)",
                    arguments: [workspace ?? owner.key, position, key]) ?? 0
            guard !toolCallIDs.isEmpty else { return .init(ordinal: preceding + 1, toolSources: [:]) }
            let matches = try Row.fetchAll(
                db,
                sql: """
                    SELECT json_extract(c.value,'$.providerID') AS call_id, MIN(m.id) AS message_id
                    FROM writer_messages m, json_each(m.tool_calls_json) c
                    WHERE m.delegation_id=? AND (m.position,m.id)<(?,?)
                      AND json_extract(m.assistant_response_json,'$.id') IS NOT NULL
                      AND json_extract(c.value,'$.providerID') IN (SELECT value FROM json_each(?))
                    GROUP BY call_id HAVING COUNT(*)=1
                    """,
                arguments: [owner.key, position, key, try SQLiteRecordCoding.json(toolCallIDs)])
            let sources = Dictionary(
                uniqueKeysWithValues: matches.map {
                    ($0["call_id"] as String, SQLiteRecordKey.id(.request, $0["message_id"]))
                })
            return .init(ordinal: preceding + 1, toolSources: sources)
        }
    }
    public func taskForMessage(_ id: String) throws -> String {
        try database.read { try Self.locate(SQLiteRecordCoding.key(id), db: $0).0.id }
    }
    public func taskForInput(_ input: String) throws -> String? {
        try database.read { db in
            var owners: Set<String> = []
            for (table, column, _) in [
                ("writer_messages", "delegation_id", "writer")
            ] {
                for key in try Int64.fetchAll(
                    db, sql: "SELECT DISTINCT \(column) FROM \(table) WHERE root_input_key=? AND \(column) IS NOT NULL",
                    arguments: [input])
                { owners.insert(Owner(key: key, request: true).id) }
            }
            guard owners.count <= 1 else { throw RecordStorageError.conflict }
            return owners.first
        }
    }
    public func inputRows(_ input: String, ownerID id: String) throws -> [WriterMessageRecord] {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            return try Row.fetchAll(
                db,
                sql: "SELECT * FROM \(owner.table) WHERE \(owner.column)=? AND root_input_key=? ORDER BY position,id",
                arguments: [owner.key, input]
            ).flatMap { try Self.records($0, owner: owner, db: db) }
        }
    }
    public func unfinishedUserMessages(ownerID id: String) throws -> [WriterMessageRecord] {
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
    static func previewSQL(owner: Owner, comparison: String = ">", descending: Bool = false) -> String {
        let order = descending ? "DESC" : "ASC"
        return
            "SELECT m.id,m.input_key,m.root_input_key,m.position,m.request_message_id,m.created_at,m.state,m.input_kind,substr(json_extract(m.user_input_json,'$.text'),1,240) AS input_text,substr(json_extract(m.assistant_response_json,'$.text'),1,240) AS response_text,json_extract(m.assistant_response_json,'$.id') AS invocation,(SELECT COALESCE(json_group_array(json_object('id',json_extract(c.value,'$.id'),'providerID',json_extract(c.value,'$.providerID'),'name',json_extract(c.value,'$.name'),'argumentsJSON',substr(CASE WHEN json_valid(json_extract(c.value,'$.argumentsJSON')) THEN (SELECT json_group_object(a.key,substr(CAST(a.value AS TEXT),1,512)) FROM json_each(json_extract(c.value,'$.argumentsJSON')) a WHERE a.key IN ('command','path','title','description','text','reason','agent_id')) ELSE '{}' END,1),'state',json_extract(c.value,'$.state'))),'[]') FROM json_each(m.tool_calls_json) c) AS tool_calls_json,json_extract(m.assistant_response_json,'$.producerMetadata') AS producer_metadata FROM \(owner.table) m WHERE m.\(owner.column)=? AND json_extract(m.assistant_response_json,'$.id') IS NOT NULL AND \(owner.preflight ? "m.workspace_id IS NULL" : "1") AND m.position>0 AND m.position\(comparison)? ORDER BY m.position \(order),m.id \(order) LIMIT ? OFFSET ?"
    }
    public func previews(
        ownerID id: String, after: UInt64 = 0, limit: Int = HistoryPaging.pageSize,
        offset: Int = 0
    ) throws -> [WriterMessagePreview] {
        try readPreviews(ownerID: id, after: after, before: nil, limit: limit, offset: offset)
    }
    public func previews(ownerID id: String, before: UInt64?, limit: Int) throws -> [WriterMessagePreview] {
        try readPreviews(ownerID: id, after: nil, before: before, limit: limit, offset: 0)
    }
    private func readPreviews(
        ownerID id: String, after: UInt64?, before: UInt64?, limit: Int, offset: Int
    ) throws -> [WriterMessagePreview] {
        let bound = after ?? before ?? UInt64(Int64.max)
        guard bound <= Int64.max, (1...50).contains(limit), offset >= 0 else { throw RecordStorageError.invalidRecord }
        let descending = after == nil
        let comparison = descending ? (before == nil ? "<=" : "<") : ">"
        let ordinalComparison = descending ? comparison : "<="
        return try database.read { db in
            let owner = try Self.owner(id, db: db)
            let args = StatementArguments(
                [owner.key, Int64(bound)] + [Int64(limit), Int64(offset)])
            let preceding =
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM \(owner.table) m WHERE m.\(owner.column)=? AND json_extract(m.assistant_response_json,'$.id') IS NOT NULL AND \(owner.preflight ? "m.workspace_id IS NULL" : "1") AND m.position>0 AND m.position\(ordinalComparison)?",
                    arguments: StatementArguments([owner.key, Int64(bound)])) ?? 0
            return try Row.fetchAll(
                db, sql: Self.previewSQL(owner: owner, comparison: comparison, descending: descending), arguments: args
            )
            .enumerated().map { index, row in
                let invocation: String? = row["invocation"]
                var value = WriterMessagePreview(
                    id: SQLiteRecordKey.id(invocation == nil ? .message : .request, row["id"]),
                    clientID: invocation ?? row["input_key"], inputID: row["root_input_key"],
                    input: row["input_text"] as String? ?? "", response: row["response_text"] as String? ?? "",
                    date: Date(timeIntervalSince1970: row["created_at"]),
                    position: UInt64(row["position"] as Int64), state: row["state"],
                    isObservation: row["input_kind"] as String == "react",
                    isInput: invocation == nil)
                value.ordinal = descending ? preceding - index : preceding + offset + index + 1
                let calls = try JSONDecoder().decode(
                    [ModelToolCall].self, from: Data((row["tool_calls_json"] as String).utf8))
                value.toolCalls = calls.map {
                    .init(name: $0.name, argumentsJSON: $0.argumentsJSON, state: $0.state.rawValue)
                }
                if let metadata: String = row["producer_metadata"] {
                    value.metadata = try JSONDecoder().decode([String: String].self, from: Data(metadata.utf8))
                }
                value.metadata["delegateID"] = row["request_message_id"]
                if calls.contains(where: { $0.state == .received }) { value.metadata["toolsPending"] = "true" }
                return value
            }
        }
    }

    public func timelineCount(ownerID id: String) throws -> Int {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            let sql = Self.previewSQL(owner: owner)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (\(sql))", arguments: [owner.key, -1, Int64.max, 0])
                ?? 0
        }
    }
    public func latestPreviews(ownerID id: String, limit: Int = 10) throws -> [WriterMessagePreview] {
        try previews(ownerID: id, limit: limit, offset: max(0, try timelineCount(ownerID: id) - limit))
    }

}
