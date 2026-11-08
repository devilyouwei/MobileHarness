import Foundation
internal import GRDB
import StorageChat
import StorageCore

extension SQLiteModelRequestLogRepository {
    static func initializeLog(agent: String, message: Int64, invocation: String, db: Database) throws {
        let now = Date().timeIntervalSince1970
        var row = ModelRequestLogRow(
            assistantMessageID: agent == "assistant" ? message : nil,
            writerMessageID: agent == "writer" ? message : nil, invocationID: invocation, createdAt: now,
            updatedAt: now)
        try row.insert(db)
    }
    public func writeRequestPayload(
        _ requestID: String, agent: String, json: String, response: String, initial: Bool,
        update: ModelRequestLogUpdate? = nil
    ) async throws {
        guard ["assistant", "writer"].contains(agent) else { throw RecordStorageError.invalidRecord }
        try database.write { db in
            let ownerColumn = agent == "assistant" ? "assistant_message_id" : "writer_message_id"
            guard
                var key = try Int64.fetchOne(
                    db,
                    sql:
                        "SELECT id FROM model_request_log WHERE invocation_id=? AND (\(ownerColumn) IS NOT NULL OR \(agent == "assistant" ? "assistant_conversation_id IS NOT NULL" : "0")) ORDER BY transport_index DESC LIMIT 1",
                    arguments: [requestID])
            else { return }
            let now = Date().timeIntervalSince1970
            switch update {
            case .request(let method, let url, let headers, let body, let at):
                if let previous = try ModelRequestLogRow.fetchOne(db, key: key), previous.captureFormat == "http" {
                    var next = ModelRequestLogRow(
                        assistantMessageID: previous.assistantMessageID,
                        writerMessageID: previous.writerMessageID,
                        assistantConversationID: previous.assistantConversationID,
                        invocationID: requestID, transportIndex: previous.transportIndex + 1,
                        generationMetaJson: previous.generationMetaJson, createdAt: now, updatedAt: now)
                    try next.insert(db)
                    guard let inserted = next.id else { throw RecordStorageError.invalidRecord }
                    key = inserted
                }
                try db.execute(
                    sql:
                        "UPDATE model_request_log SET method=?,url=?,request_headers_json=?,request_body=?,response_body=X'',capture_format='http',started_at=?,updated_at=?,capture_details_json=? WHERE id=?",
                    arguments: [
                        method, url, try SQLiteRecordCoding.json(headers), body, at.timeIntervalSince1970, now,
                        "{\"transport\":\"URLSession application bytes; transfer decoding and visible headers\"}", key,
                    ])
            case .response(let status, let headers, _):
                try db.execute(
                    sql: "UPDATE model_request_log SET http_status=?,response_headers_json=?,updated_at=? WHERE id=?",
                    arguments: [status, try SQLiteRecordCoding.json(headers), now, key])
            case .bytes(let bytes, let at):
                guard bytes.count <= 65_536 else { throw RecordStorageError.invalidRecord }
                try db.execute(
                    sql:
                        "UPDATE model_request_log SET response_body=CAST(response_body || ? AS BLOB),first_byte_at=COALESCE(first_byte_at,?),updated_at=? WHERE id=?",
                    arguments: [bytes, at.timeIntervalSince1970, now, key])
            case .finished(let at, let error):
                try db.execute(
                    sql:
                        "UPDATE model_request_log SET capture_state=?,completed_at=?,updated_at=?,capture_details_json=json_patch(capture_details_json,?) WHERE id=?",
                    arguments: [
                        error == nil ? "completed" : "partial", at.timeIntervalSince1970, now,
                        try SQLiteRecordCoding.json(error.map { ["error": $0] } ?? [:]), key,
                    ])
            case nil:
                // The log is created exactly once with business admission. No write can recreate a cleared log.
                try db.execute(
                    sql:
                        "UPDATE model_request_log SET request_body=?,response_body=?,capture_state=?,updated_at=? WHERE id=? AND capture_format='local'",
                    arguments: [Data(json.utf8), Data(response.utf8), initial ? "capturing" : "completed", now, key])
            }
        }
    }
    public func requestPayload(_ id: String, agent: String) async throws -> ModelRequestLog? {
        try database.read { db in
            guard ["assistant", "writer"].contains(agent) else { throw RecordStorageError.invalidRecord }
            let column = agent == "assistant" ? "assistant_message_id" : "writer_message_id"
            return try ModelRequestLogRow.fetchOne(
                db, sql: "SELECT * FROM model_request_log WHERE \(column)=? ORDER BY transport_index DESC LIMIT 1",
                arguments: [try SQLiteRecordCoding.key(id)]
            ).map {
                .init(
                    requestJSON: String(decoding: $0.requestBody, as: UTF8.self),
                    responseJSON: String(decoding: $0.responseBody, as: UTF8.self), format: $0.captureFormat,
                    captureState: $0.captureState)
            }
        }
    }
    public func clearRequestLogs(agent: String, requestID: String?) async throws {
        guard ["assistant", "writer"].contains(agent) else { throw RecordStorageError.invalidRecord }
        try database.write { db in
            if let requestID {
                guard ["assistant", "writer"].contains(agent) else { throw RecordStorageError.invalidRecord }
                try db.execute(
                    sql:
                        "DELETE FROM model_request_log WHERE \(agent == "assistant" ? "assistant_message_id":"writer_message_id")=?",
                    arguments: [try SQLiteRecordCoding.key(requestID)])
            } else {
                try db.execute(sql: "DELETE FROM model_request_log")
            }
        }
    }
    static let generationKeys: Set<String> = [
        "model", "maximumOutputTokens", "temperature", "modelRequestStartedAt", "modelRequestCompletedAt",
        "firstTokenLatency", "firstTokenAt", "tokenUsage", "finishReason", "requestParametersJSON",
        "responseEventsJSON", "requestJSON", "request", "logsCleared", "error", "failureDiagnostic",
    ]

    static func saveGenerationMetadata(_ metadata: [String: Any], invocation: String, at now: Double, db: Database)
        throws
    {
        try db.execute(
            sql: "UPDATE model_request_log SET generation_meta_json=?,updated_at=? WHERE invocation_id=?",
            arguments: [try SQLiteRecordCoding.json(metadata), now, invocation])
    }
    static func generationMetadata(_ invocation: String, db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql:
                "SELECT generation_meta_json FROM model_request_log WHERE invocation_id=? ORDER BY transport_index DESC LIMIT 1",
            arguments: [invocation])
    }

}
