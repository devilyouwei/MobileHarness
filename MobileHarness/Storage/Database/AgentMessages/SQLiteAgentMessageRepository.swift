import Foundation
internal import GRDB
import StorageCore
import StorageTasks

public final class SQLiteAgentMessageRepository: AgentMessageRepository {
    public var storageScope: UUID { database.storageScope }
    let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }
    static func enqueue(_ value: AgentCommunicationRecord, db: Database) throws {
        guard UUID(uuidString: value.id) != nil, !value.sender.isEmpty, !value.receiver.isEmpty,
            !value.contract.isEmpty, !value.dedupeKey.isEmpty, value.payload.count <= 128 * 1024
        else { throw RecordStorageError.invalidRecord }
        let json = try SQLiteRecordCoding.json(JSONSerialization.jsonObject(with: value.payload))
        if let row = try AgentMessageRow.fetchOne(
            db,
            sql:
                "SELECT * FROM agent_messages WHERE id=? OR (sender_agent_id=? AND receiver_agent_id=? AND dedupe_key=?)",
            arguments: [value.id, value.sender, value.receiver, value.dedupeKey])
        {
            guard row.id == value.id, row.senderAgentID == value.sender, row.receiverAgentID == value.receiver,
                row.contract == value.contract, row.payloadJson == json, row.correlationID == value.correlationID,
                row.replyToID == value.replyTo, row.senderContext == value.senderContext,
                row.sourceSessionID == value.sourceSessionID
            else { throw RecordStorageError.conflict }
            return
        }
        var row = AgentMessageRow(
            id: value.id, senderAgentID: value.sender, receiverAgentID: value.receiver, contract: value.contract,
            payloadJson: json, correlationID: value.correlationID, replyToID: value.replyTo,
            senderContext: value.senderContext, sourceSessionID: value.sourceSessionID, dedupeKey: value.dedupeKey,
            createdAt: Date().timeIntervalSince1970)
        try row.insert(db)
    }
    public func observationRequests(sender: String, after: String?, limit: Int) async throws
        -> [AgentCommunicationRecord]
    {
        guard !sender.isEmpty, (1...64).contains(limit) else { throw RecordStorageError.invalidRecord }
        let ids = try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT r.id FROM agent_messages r WHERE r.sender_agent_id=? AND r.id>?
                        AND r.contract IN ('agent.task.v1','agent.task.request','agent.taskMessage','task.request') AND r.reply_to_id IS NULL
                        AND r.delivery_state!='dead_letter'
                        AND NOT EXISTS(SELECT 1 FROM agent_messages e WHERE e.correlation_id=r.id AND e.receiver_agent_id=r.sender_agent_id
                            AND e.consumed_at IS NOT NULL AND e.contract IN ('agent.task.events.v1','agent.task.response','writer.completion')
                            AND (json_extract(e.payload_json,'$.signal.kind')='result' OR json_extract(e.payload_json,'$.kind')='result'
                                 OR json_extract(e.payload_json,'$.rejection') IS NOT NULL OR e.contract='writer.completion'))
                    ORDER BY r.id LIMIT ?
                    """, arguments: [sender, after ?? "", limit])
        }
        var values: [AgentCommunicationRecord] = []
        for id in ids { if let record = try await agentMessage(id) { values.append(record) } }
        return values
    }
    public func archiveInvocationEvidence(_ id: String, ownerContext: String, data: Data) async throws {
        guard UUID(uuidString: id) != nil, !ownerContext.isEmpty, ownerContext.utf8.count <= 256,
            !data.isEmpty, data.count <= 4 * 1024 * 1024 + 1024
        else { throw RecordStorageError.invalidRecord }
        try database.write { db in
            if let row = try Row.fetchOne(
                db, sql: "SELECT owner_context,payload FROM invocation_evidence WHERE id=?", arguments: [id])
            {
                guard row["owner_context"] as String == ownerContext, row["payload"] as Data == data else {
                    throw RecordStorageError.conflict
                }
                return
            }
            try db.execute(
                sql: "INSERT INTO invocation_evidence(id,owner_context,payload,created_at) VALUES(?,?,?,?)",
                arguments: [id, ownerContext, data, Date().timeIntervalSince1970])
        }
    }
    public func invocationEvidence(_ id: String) async throws -> Data {
        try database.read { db in
            guard
                let data = try Data.fetchOne(
                    db, sql: "SELECT payload FROM invocation_evidence WHERE id=?", arguments: [id])
            else {
                throw RecordStorageError.missingRecord
            }
            return data
        }
    }
    public func taskEvents(reference: String, receiver: String, after: Int64? = nil, limit: Int = 32) async throws
        -> AgentTaskEventPage
    {
        guard UUID(uuidString: reference) != nil, !receiver.isEmpty, (1...64).contains(limit), (after ?? 0) >= 0 else {
            throw RecordStorageError.invalidRecord
        }
        return try database.read { db in
            guard let root = try AgentMessageRow.fetchOne(db, key: reference), root.senderAgentID == receiver else {
                throw RecordStorageError.invalidRecord
            }
            let saved =
                try Int64.fetchOne(
                    db, sql: "SELECT position FROM task_observation_cursors WHERE task_ref=? AND receiver_agent_id=?",
                    arguments: [reference, receiver]) ?? 0
            let cursor = after ?? saved
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT rowid AS position,id FROM agent_messages
                    WHERE (correlation_id=? OR reply_to_id=?) AND receiver_agent_id=? AND rowid>?
                      AND contract IN ('agent.task.events.v1','agent.task.response','writer.completion')
                    ORDER BY rowid LIMIT ?
                    """, arguments: [reference, reference, receiver, cursor, limit])
            let records = try rows.map { row -> AgentTaskEventRecord in
                let id: String = row["id"]
                guard let value = try AgentMessageRow.fetchOne(db, key: id) else {
                    throw RecordStorageError.missingRecord
                }
                return AgentTaskEventRecord(
                    position: row["position"],
                    message: .init(
                        id: value.id, sender: value.senderAgentID, receiver: value.receiverAgentID,
                        contract: value.contract, payload: Data(value.payloadJson.utf8),
                        correlationID: value.correlationID,
                        replyTo: value.replyToID, senderContext: value.senderContext,
                        sourceSessionID: value.sourceSessionID,
                        dedupeKey: value.dedupeKey))
            }
            return AgentTaskEventPage(events: records, cursor: cursor)
        }
    }
    public func consumeTaskEvents(reference: String, receiver: String, through: Int64) async throws {
        guard through > 0 else { throw RecordStorageError.invalidRecord }
        try database.write { db in
            guard let root = try AgentMessageRow.fetchOne(db, key: reference), root.senderAgentID == receiver,
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(SELECT 1 FROM agent_messages WHERE rowid=? AND receiver_agent_id=?
                            AND (correlation_id=? OR reply_to_id=?)
                            AND contract IN ('agent.task.events.v1','agent.task.response','writer.completion'))
                        """, arguments: [through, receiver, reference, reference]) == true
            else { throw RecordStorageError.invalidRecord }
            let now = Date().timeIntervalSince1970
            // Only the acknowledged event is consumed; the cursor never passes an earlier unconsumed event.
            try db.execute(
                sql: """
                    UPDATE agent_messages SET consumed_at=COALESCE(consumed_at,?),received_at=COALESCE(received_at,?)
                    WHERE rowid=? AND receiver_agent_id=?
                    """, arguments: [now, now, through, receiver])
            guard
                let id = try String.fetchOne(
                    db, sql: "SELECT id FROM agent_messages WHERE rowid=?", arguments: [through])
            else { throw RecordStorageError.missingRecord }
            try Self.advanceConsumedTaskCursor(id: id, receiver: receiver, db: db)
        }
    }
    public func enqueueAgentMessage(_ value: AgentCommunicationRecord) async throws {
        try database.write { try Self.enqueue(value, db: $0) }
    }
    public func nextAgentDelivery(sender: String, contract: String) async throws -> Date? {
        try database.read { db in
            try Double.fetchOne(
                db,
                sql:
                    "SELECT MIN(CASE WHEN delivery_state='in_flight' THEN claim_expires_at ELSE COALESCE(next_attempt_at,0) END) FROM agent_messages WHERE sender_agent_id=? AND (contract=? OR (?='agent.task.events.v1' AND contract IN ('agent.task.response','writer.completion'))) AND delivery_state IN ('pending','in_flight')",
                arguments: [sender, contract, contract]
            ).map { Date(timeIntervalSince1970: $0) }
        }
    }
    public func agentReply(to id: String, contract: String) async throws -> AgentCommunicationRecord? {
        let key = try database.read { db in
            try String.fetchOne(
                db,
                sql:
                    "SELECT id FROM agent_messages WHERE reply_to_id=? AND (contract=? OR (?='agent.task.events.v1' AND contract IN ('agent.task.response','writer.completion'))) ORDER BY created_at DESC LIMIT 1",
                arguments: [id, contract, contract])
        }
        guard let key else { return nil }
        return try await agentMessage(key)
    }
    public func agentMessage(_ id: String) async throws -> AgentCommunicationRecord? {
        try database.read { db in
            try AgentMessageRow.fetchOne(db, key: id).map {
                .init(
                    id: $0.id, sender: $0.senderAgentID, receiver: $0.receiverAgentID, contract: $0.contract,
                    payload: Data($0.payloadJson.utf8), correlationID: $0.correlationID, replyTo: $0.replyToID,
                    senderContext: $0.senderContext, sourceSessionID: $0.sourceSessionID, dedupeKey: $0.dedupeKey)
            }
        }
    }
    public func receiveAgentMessage(_ id: String, receiver: String, consumed: Bool) async throws {
        try database.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql:
                    "UPDATE agent_messages SET delivery_state=CASE WHEN contract IN ('agent.task.events.v1','agent.task.response','writer.completion') THEN delivery_state ELSE 'received' END,received_at=COALESCE(received_at,?),consumed_at=CASE WHEN ? THEN COALESCE(consumed_at,?) ELSE consumed_at END WHERE id=? AND receiver_agent_id=?",
                arguments: [now, consumed, now, id, receiver])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
            if consumed { try Self.advanceConsumedTaskCursor(id: id, receiver: receiver, db: db) }
        }
    }
    private static func advanceConsumedTaskCursor(id: String, receiver: String, db: Database) throws {
        guard let event = try AgentMessageRow.fetchOne(db, key: id),
            ["agent.task.events.v1", "agent.task.response", "writer.completion"].contains(event.contract),
            let root = try AgentMessageRow.fetchOne(db, key: event.correlationID), root.senderAgentID == receiver
        else { return }
        let reference = event.correlationID
        let saved = try Int64.fetchOne(
            db, sql: "SELECT position FROM task_observation_cursors WHERE task_ref=? AND receiver_agent_id=?",
            arguments: [reference, receiver])
        let firstPending =
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT MIN(rowid) FROM agent_messages WHERE receiver_agent_id=? AND (correlation_id=? OR reply_to_id=?)
                        AND contract IN ('agent.task.events.v1','agent.task.response','writer.completion') AND consumed_at IS NULL
                    """, arguments: [receiver, reference, reference]) ?? Int64.max
        guard
            let position = try Int64.fetchOne(
                db,
                sql: """
                    SELECT MAX(rowid) FROM agent_messages WHERE receiver_agent_id=? AND (correlation_id=? OR reply_to_id=?)
                        AND contract IN ('agent.task.events.v1','agent.task.response','writer.completion') AND consumed_at IS NOT NULL AND rowid<?
                    """, arguments: [receiver, reference, reference, firstPending]), position > (saved ?? 0)
        else { return }
        if saved == nil {
            let count =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM task_observation_cursors WHERE receiver_agent_id=?",
                    arguments: [receiver]) ?? 0
            guard count < 256 else { throw RecordStorageError.busy }
        }
        try db.execute(
            sql: """
                INSERT INTO task_observation_cursors(task_ref,receiver_agent_id,position) VALUES(?,?,?)
                ON CONFLICT(task_ref,receiver_agent_id) DO UPDATE SET position=MAX(position,excluded.position)
                """, arguments: [reference, receiver, position])
    }
    public func isAgentMessageConsumed(_ id: String) async throws -> Bool {
        try database.read { db in
            guard let row = try AgentMessageRow.fetchOne(db, key: id) else { throw RecordStorageError.missingRecord }
            return row.consumedAt != nil
        }
    }
    public func associateAgentMessage(_ id: String, receiver: String, replyTo: String) async throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE agent_messages SET correlation_id=?,reply_to_id=?
                    WHERE id=? AND receiver_agent_id=? AND consumed_at IS NULL AND id<>?
                      AND (reply_to_id IS NULL OR reply_to_id=?)
                      AND EXISTS(SELECT 1 FROM agent_messages root
                                 WHERE root.id=? AND root.receiver_agent_id=agent_messages.receiver_agent_id
                                   AND root.sender_agent_id=agent_messages.sender_agent_id)
                    """, arguments: [replyTo, replyTo, id, receiver, replyTo, replyTo, replyTo])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
        }
    }
    public func rejectAgentMessage(_ id: String, eventID: String, payload: Data) async throws {
        try database.write { db in
            guard let request = try AgentMessageRow.fetchOne(db, key: id) else {
                throw RecordStorageError.missingRecord
            }
            guard request.consumedAt == nil else { return }
            guard ["agent.task.v1", "agent.task.request"].contains(request.contract),
                !request.senderAgentID.isEmpty,
                request.receiverAgentID == "writer"
            else { throw RecordStorageError.invalidRecord }
            let result = AgentCommunicationRecord(
                id: eventID, sender: request.receiverAgentID, receiver: request.senderAgentID,
                contract: "agent.task.events.v1", payload: payload,
                correlationID: request.correlationID, replyTo: id, senderContext: request.senderContext,
                sourceSessionID: request.sourceSessionID,
                dedupeKey: id + ":rejected")
            try Self.enqueue(result, db: db)
            try db.execute(
                sql:
                    "UPDATE agent_messages SET consumed_at=COALESCE(consumed_at,?),received_at=COALESCE(received_at,?),delivery_state='received' WHERE id=?",
                arguments: [Date().timeIntervalSince1970, Date().timeIntervalSince1970, id])
        }
    }
    public func failAgentMessage(_ id: String, failure: String) async throws {
        try database.write { db in
            try db.execute(
                sql:
                    "UPDATE agent_messages SET delivery_state='dead_letter',last_error=?,claim_token=NULL,claim_expires_at=NULL WHERE id=? AND consumed_at IS NULL",
                arguments: [failure, id])
        }
    }
}

extension SQLiteAgentMessageRepository {
    static func consumeSource(_ source: String, at now: Double, db: Database) throws {
        try db.execute(
            sql:
                "UPDATE agent_messages SET consumed_at=COALESCE(consumed_at,?),received_at=COALESCE(received_at,?),delivery_state='received' WHERE id=?",
            arguments: [now, now, source])
    }
}
