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
                row.replyToID == value.replyTo, row.senderContext == value.senderContext
            else { throw RecordStorageError.conflict }
            return
        }
        var row = AgentMessageRow(
            id: value.id, senderAgentID: value.sender, receiverAgentID: value.receiver, contract: value.contract,
            payloadJson: json, correlationID: value.correlationID, replyToID: value.replyTo,
            senderContext: value.senderContext, dedupeKey: value.dedupeKey, createdAt: Date().timeIntervalSince1970)
        try row.insert(db)
    }
    public func enqueueAgentMessage(_ value: AgentCommunicationRecord) async throws {
        try database.write { try Self.enqueue(value, db: $0) }
    }
    public func nextAgentDelivery(sender: String, contract: String) async throws -> Date? {
        try database.read { db in
            try Double.fetchOne(
                db,
                sql:
                    "SELECT MIN(CASE WHEN delivery_state='in_flight' THEN claim_expires_at ELSE COALESCE(next_attempt_at,0) END) FROM agent_messages WHERE sender_agent_id=? AND contract=? AND delivery_state IN ('pending','in_flight')",
                arguments: [sender, contract]
            ).map { Date(timeIntervalSince1970: $0) }
        }
    }
    public func agentReply(to id: String, contract: String) async throws -> AgentCommunicationRecord? {
        let key = try database.read { db in
            try String.fetchOne(
                db,
                sql:
                    "SELECT id FROM agent_messages WHERE reply_to_id=? AND contract=? ORDER BY created_at DESC LIMIT 1",
                arguments: [id, contract])
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
                    senderContext: $0.senderContext, dedupeKey: $0.dedupeKey)
            }
        }
    }
    public func receiveAgentMessage(_ id: String, receiver: String, consumed: Bool) async throws {
        try database.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql:
                    "UPDATE agent_messages SET delivery_state='received',received_at=COALESCE(received_at,?),consumed_at=CASE WHEN ? THEN COALESCE(consumed_at,?) ELSE consumed_at END WHERE id=? AND receiver_agent_id=?",
                arguments: [now, consumed, now, id, receiver])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
        }
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
            guard request.contract == "agent.task.request", request.senderAgentID == "assistant",
                request.receiverAgentID == "writer"
            else { throw RecordStorageError.invalidRecord }
            let result = AgentCommunicationRecord(
                id: eventID, sender: request.receiverAgentID, receiver: request.senderAgentID,
                contract: "agent.task.response", payload: payload,
                correlationID: request.correlationID, replyTo: id, senderContext: request.senderContext,
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
