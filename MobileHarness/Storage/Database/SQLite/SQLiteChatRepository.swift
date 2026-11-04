import Foundation
internal import GRDB
import StorageChat
import StorageCore

public final class SQLiteChatRepository: ChatRepository {
    public var storageScope: UUID { database.storageScope }
    private let database: SQLiteDatabase
    internal init(database: SQLiteDatabase) { self.database = database }
    internal static let schemaSQL = """
        CREATE TABLE dialogs(id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT NOT NULL,
                                created_at REAL NOT NULL, archived_at REAL, title TEXT, title_error TEXT,
                                revision INTEGER NOT NULL DEFAULT 0, input_count INTEGER NOT NULL DEFAULT 0, latest_input TEXT, recovery BLOB);
        CREATE UNIQUE INDEX current_dialog ON dialogs(agent) WHERE archived_at IS NULL;
        CREATE INDEX dialog_archive ON dialogs(agent,id DESC) WHERE archived_at IS NOT NULL;
        CREATE TABLE evidence(hash TEXT PRIMARY KEY, data BLOB NOT NULL);
        CREATE TABLE evidence_refs(parent_hash TEXT NOT NULL REFERENCES evidence(hash) ON DELETE CASCADE,
                                child_hash TEXT NOT NULL REFERENCES evidence(hash),PRIMARY KEY(parent_hash,child_hash));
        CREATE INDEX evidence_child ON evidence_refs(child_hash);
        CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT, dialog_id INTEGER NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
                                client_id TEXT NOT NULL, input_id TEXT NOT NULL, role TEXT NOT NULL, kind TEXT NOT NULL,
                                position INTEGER NOT NULL, created_at REAL NOT NULL, body TEXT NOT NULL, preview TEXT NOT NULL, state TEXT NOT NULL,
                                reply_to_message_id INTEGER REFERENCES messages(id) ON DELETE SET NULL,
                                task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL, detail_hash TEXT NOT NULL REFERENCES evidence(hash),
                                UNIQUE(dialog_id,client_id,role));
        CREATE INDEX message_order ON messages(dialog_id,position,id);
        CREATE INDEX message_input ON messages(dialog_id,input_id);
        CREATE INDEX message_origin ON messages(input_id,dialog_id);
        CREATE INDEX message_kind ON messages(dialog_id,kind,position);
        CREATE INDEX message_task ON messages(task_id,position,id);
        CREATE INDEX message_detail ON messages(detail_hash);
        CREATE INDEX message_active ON messages(id) WHERE state='generating';
        CREATE TABLE task_messages(task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                                message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE, PRIMARY KEY(task_id,message_id));
        CREATE TABLE message_media(message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                                media_id INTEGER NOT NULL REFERENCES media_files(id), PRIMARY KEY(message_id,media_id));
        CREATE INDEX media_message ON message_media(media_id,message_id);
        """
    public func current(agent: String, includingRecovery: Bool = true) throws -> DialogRecord {
        if let row = try database.read({ db in
            try Row.fetchOne(
                db,
                sql:
                    "SELECT \(includingRecovery ? "*" : Self.dialogMetadataColumns) FROM dialogs WHERE agent=? AND archived_at IS NULL",
                arguments: [agent])
        }) {
            return Self.dialog(row)
        }
        return try database.write { db in
            if try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM dialogs WHERE agent=? AND archived_at IS NULL", arguments: [agent]) == 0
            {
                var dialog = SQLiteDialogRow(agent: agent, createdAt: Date().timeIntervalSince1970)
                try dialog.insert(db)
            }
            guard
                let row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT \(includingRecovery ? "*" : Self.dialogMetadataColumns) FROM dialogs WHERE agent=? AND archived_at IS NULL",
                    arguments: [agent])
            else { throw RecordStorageError.missingRecord }
            return Self.dialog(row)
        }
    }
    public func listDialogs(agent: String, before: Int64? = nil, limit: Int = HistoryPaging.pageSize) throws
        -> [DialogRecord]
    {
        guard (1...50).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT d.id,d.agent,d.created_at,d.archived_at,d.title,d.title_error,d.revision,d.input_count,d.latest_input,NULL AS recovery FROM dialogs d WHERE agent=? AND archived_at IS NOT NULL \(before == nil ? "" : "AND id<?") ORDER BY id DESC LIMIT ?
                    """,
                arguments: StatementArguments([agent])
                    + (before.map { StatementArguments([$0]) } ?? StatementArguments()) + StatementArguments([limit])
            ).map(Self.dialog)
        }
    }
    private static func dialog(_ row: Row) -> DialogRecord {
        let number: Int64 = row["id"]
        let archived: Double? = row["archived_at"]
        return DialogRecord(
            id: SQLiteRecordKey.id(.dialog, number), agent: row["agent"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            archivedAt: archived.map(Date.init(timeIntervalSince1970:)), title: row["title"],
            titleError: row["title_error"],
            revision: UInt64(row["revision"] as Int64), recovery: row["recovery"], count: row["input_count"] ?? 0,
            latestUser: row["latest_input"])
    }
    public func dialog(_ id: String, includingRecovery: Bool = true) throws -> DialogRecord {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        return try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT \(includingRecovery ? "*" : Self.dialogMetadataColumns) FROM dialogs WHERE id=?",
                    arguments: [key])
            else {
                throw RecordStorageError.missingRecord
            }
            return Self.dialog(row)
        }
    }
    public func beginMessage(dialog id: String, identity: MessageIdentity) throws -> String {
        let dialog = try BusinessRecordID.number(id, kind: .dialog)
        guard identity.order <= Int64.max, !identity.clientID.isEmpty, identity.clientID.utf8.count <= 128,
            !identity.inputID.isEmpty, identity.inputID.utf8.count <= 128,
            (identity.role == "assistant" && identity.kind == "response")
                || (identity.role == "user" && ["input", "observation"].contains(identity.kind))
        else { throw RecordStorageError.invalidRecord }
        let task = try identity.taskID.map { try BusinessRecordID.number($0, kind: .task) }
        let reply = try identity.replyTo.map { try BusinessRecordID.number($0, kind: .message) }
        return try database.write { db in
            guard
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM dialogs WHERE id=? AND archived_at IS NULL", arguments: [dialog])
                    == 1
            else { throw RecordStorageError.conflict }
            if let existing = try SQLiteMessageRow.fetchOne(
                db, key: ["dialog_id": dialog, "client_id": identity.clientID, "role": identity.role])
            {
                guard existing.inputID == identity.inputID, existing.kind == identity.kind else {
                    throw RecordStorageError.invalidRecord
                }
                return SQLiteRecordKey.id(.message, try existing.requireID())
            }
            if let reply {
                guard
                    try Int64.fetchOne(db, sql: "SELECT dialog_id FROM messages WHERE id=?", arguments: [reply])
                        == dialog
                else { throw RecordStorageError.invalidRecord }
            }
            var row = SQLiteMessageRow(
                dialogID: dialog, clientID: identity.clientID, inputID: identity.inputID,
                role: identity.role, kind: identity.kind, position: Int64(identity.order),
                createdAt: identity.date.timeIntervalSince1970, body: "", preview: "", state: "generating",
                replyToMessageID: reply, taskID: task, detailHash: try Self.blob(Data(), in: db))
            try row.insert(db)
            let number = try row.requireID()
            if let task {
                try db.execute(sql: "INSERT INTO task_messages VALUES(?,?)", arguments: [task, number])
            }
            return SQLiteRecordKey.id(.message, number)
        }
    }
    @discardableResult public func save(
        dialog id: String, revision: UInt64, recovery: Data?, messages: [MessageRecord],
        summaries: [TaskCompressionRecord]
    ) throws -> [MessageReference] {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        guard revision <= Int64.max else { throw RecordStorageError.invalidRecord }
        return try database.write { db in
            var references: [MessageReference] = []
            guard
                let dialog = try SQLiteDialogRow.fetchOne(
                    db, sql: "SELECT id,agent,created_at,archived_at FROM dialogs WHERE id=?", arguments: [key])
            else { throw RecordStorageError.missingRecord }
            for message in messages {
                guard message.order <= Int64.max else { throw RecordStorageError.invalidRecord }
                let hash = try Self.packDetail(message.detail, in: db)
                let task = try message.taskID.map { try BusinessRecordID.number($0, kind: .task) }
                let parent: Int64?
                if message.kind == "observation" {
                    parent = try Int64.fetchOne(
                        db,
                        sql:
                            "SELECT id FROM messages WHERE dialog_id=? AND input_id=? AND role='assistant' AND position<=? ORDER BY position DESC LIMIT 1",
                        arguments: [key, message.inputID, Int64(message.order)])
                } else if message.role == "assistant" {
                    parent =
                        try Int64.fetchOne(
                            db,
                            sql:
                                "SELECT id FROM messages WHERE dialog_id=? AND client_id=? AND role='user' AND kind='observation'",
                            arguments: [key, message.clientID])
                        ?? Int64.fetchOne(
                            db,
                            sql:
                                "SELECT id FROM messages WHERE dialog_id=? AND client_id=? AND role='user' AND kind='input'",
                            arguments: [key, message.inputID])
                } else {
                    parent = nil
                }
                let existing = try SQLiteMessageRow.fetchOne(
                    db, key: ["dialog_id": key, "client_id": message.clientID, "role": message.role])
                guard dialog.archivedAt == nil || existing != nil else { throw RecordStorageError.conflict }
                if let id = message.id {
                    guard existing?.id == BusinessRecordID(rawValue: id)?.number,
                        BusinessRecordID(rawValue: id)?.kind == .message
                    else { throw RecordStorageError.invalidRecord }
                }
                guard existing.map({ $0.inputID == message.inputID && $0.kind == message.kind }) ?? true else {
                    throw RecordStorageError.invalidRecord
                }
                var row = SQLiteMessageRow(
                    id: existing?.id, dialogID: key, clientID: message.clientID, inputID: message.inputID,
                    role: message.role, kind: message.kind, position: existing?.position ?? Int64(message.order),
                    createdAt: existing?.createdAt ?? message.date.timeIntervalSince1970, body: message.body,
                    preview: String(message.body.prefix(240)), state: message.state,
                    replyToMessageID: existing?.replyToMessageID ?? parent, taskID: task, detailHash: hash)
                try row.save(db)
                let insertedID = try row.requireID()
                references.append(
                    MessageReference(
                        id: SQLiteRecordKey.id(.message, insertedID), clientID: message.clientID, role: message.role))
                if message.kind == "input", existing == nil || existing?.detailHash == Self.emptyDetailHash {
                    try db.execute(
                        sql: "UPDATE dialogs SET input_count=input_count+1,latest_input=? WHERE id=?",
                        arguments: [String(message.body.prefix(80)), key])
                }
                let messageKey = row.id
                if let task, let messageKey {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO task_messages VALUES(?,?)", arguments: [task, messageKey])
                }
                if let messageKey {
                    // References are explicit JSON media IDs; raw body is never interpreted as instructions.
                    if let json = try? JSONSerialization.jsonObject(with: message.detail) {
                        for media in Self.mediaReferences(json) {
                            if let reference = BusinessRecordID(rawValue: media), reference.kind == .media {
                                try db.execute(
                                    sql: "INSERT OR IGNORE INTO message_media SELECT ?,id FROM media_files WHERE id=?",
                                    arguments: [messageKey, reference.number])
                            }
                        }
                    }
                }
            }
            for summary in summaries {
                let task = try BusinessRecordID.number(summary.id, kind: .task)
                let hash = try Self.blob(summary.detail, in: db)
                try db.execute(
                    sql:
                        "UPDATE tasks SET dialog_id=?,goal=?,status=?,summary=?,failure=?,finished_at=?,compression_hash=?,first_position=(SELECT MIN(position) FROM messages WHERE task_id=tasks.id AND role='assistant') WHERE id=?",
                    arguments: [
                        key, summary.goal, summary.status, summary.summary, summary.failure,
                        summary.finishedAt.timeIntervalSince1970, hash, task,
                    ])
                for source in summary.sources {
                    try db.execute(
                        sql:
                            "INSERT OR IGNORE INTO task_messages SELECT ?,id FROM messages WHERE dialog_id=? AND client_id=?",
                        arguments: [task, key, source])
                }
            }
            try db.execute(
                sql: "UPDATE dialogs SET revision=?,recovery=? WHERE id=?", arguments: [Int64(revision), recovery, key])
            return references
        }
    }
    public func messages(dialog id: String, after: Int64? = nil, limit: Int = 50) throws
        -> [MessageRecord]
    {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        guard (1...50).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            var position: Int64 = 0
            if let after {
                guard
                    let stored = try Int64.fetchOne(
                        db, sql: "SELECT position FROM messages WHERE dialog_id=? AND id=?", arguments: [key, after])
                else { throw RecordStorageError.missingRecord }
                position = stored
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT m.*,e.data FROM messages m JOIN evidence e ON e.hash=m.detail_hash
                    WHERE dialog_id=? AND (m.position,m.id)>(?,?) ORDER BY m.position,m.id LIMIT ?
                    """, arguments: [key, position, after ?? 0, limit])
            return try rows.map { row in
                let task: Int64? = row["task_id"]
                return MessageRecord(
                    clientID: row["client_id"], inputID: row["input_id"], role: row["role"], kind: row["kind"],
                    order: UInt64(row["position"] as Int64), date: Date(timeIntervalSince1970: row["created_at"]),
                    body: row["body"], state: row["state"], taskID: task.map { SQLiteRecordKey.id(.task, $0) },
                    detail: try Self.unpackDetail(row["data"], in: db), id: SQLiteRecordKey.id(.message, row["id"]))
            }
        }
    }
    public func compressionData(dialog id: String, taskIDs: [String]? = nil) throws -> [Data] {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        let tasks = try taskIDs.map { try $0.map { try BusinessRecordID.number($0, kind: .task) } }
        if tasks?.isEmpty == true { return [] }
        return try database.read { db in
            let filter =
                tasks.map { " AND t.id IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" }
                ?? ""
            return try Data.fetchAll(
                db,
                sql: "SELECT e.data FROM tasks t JOIN evidence e ON t.compression_hash=e.hash WHERE t.dialog_id=?"
                    + filter + " ORDER BY t.id", arguments: StatementArguments([key] + (tasks ?? [])))
        }
    }
    public func rotate(_ id: String, agent: String) throws -> DialogRecord {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        return try database.write { db in
            try db.execute(
                sql: "UPDATE dialogs SET archived_at=? WHERE id=? AND agent=? AND archived_at IS NULL",
                arguments: [Date().timeIntervalSince1970, key, agent])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
            var dialog = SQLiteDialogRow(agent: agent, createdAt: Date().timeIntervalSince1970)
            try dialog.insert(db)
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM dialogs WHERE id=?", arguments: [db.lastInsertedRowID])
            else { throw RecordStorageError.missingRecord }
            return Self.dialog(row)
        }
    }
    public func setTitle(_ title: String?, error: String?, dialog id: String) throws {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        try database.write { db in
            try db.execute(sql: "UPDATE dialogs SET title=?,title_error=? WHERE id=?", arguments: [title, error, key])
        }
    }
    public func deleteDialog(_ id: String) throws {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        try database.write { db in
            try db.execute(sql: "DELETE FROM dialogs WHERE id=? AND archived_at IS NOT NULL", arguments: [key])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
            try db.execute(
                sql:
                    "DELETE FROM evidence WHERE hash IN (SELECT e.hash FROM evidence e WHERE NOT EXISTS(SELECT 1 FROM messages m WHERE m.detail_hash=e.hash) AND NOT EXISTS(SELECT 1 FROM tasks t WHERE t.compression_hash=e.hash) AND NOT EXISTS(SELECT 1 FROM evidence_refs r WHERE r.child_hash=e.hash) LIMIT 128)"
            )
        }
    }
    public func previews(
        dialog id: String, after: UInt64 = 0, taskID: String? = nil, limit: Int = HistoryPaging.pageSize,
        offset: Int = 0
    )
        throws -> [MessagePreview]
    {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        let task = try taskID.map { try BusinessRecordID.number($0, kind: .task) }
        guard after <= Int64.max, (1...50).contains(limit), offset >= 0 else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: Self.previewSQL(task: task != nil),
                arguments: StatementArguments(
                    [key, Int64(after)] + (task.map { [$0] } ?? []) + [Int64(limit), Int64(offset)])
            ).map { row in
                let taskKey: Int64? = row["task_id"]
                var preview = MessagePreview(
                    id: SQLiteRecordKey.id(.message, row["id"]), clientID: row["client_id"], inputID: row["input_id"],
                    input: row["input"], response: row["response"],
                    date: Date(timeIntervalSince1970: row["created_at"]),
                    position: UInt64(row["position"] as Int64), state: row["state"],
                    taskID: taskKey.map { SQLiteRecordKey.id(.task, $0) }, isObservation: row["observation"],
                    isInput: row["role"] as String == "user")
                preview.ordinal = row["ordinal"]
                let metadata: Data = row["preview_metadata"]
                if !metadata.isEmpty,
                    let envelope = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
                    let value = envelope["value"] as? [String: Any]
                {
                    preview.metadata = value["producerMetadata"] as? [String: String] ?? [:]
                    if let decision = value["decisionMetadata"] as? [String: Any] {
                        preview.metadata["phase"] = decision["mode"] as? String
                        preview.metadata["runID"] = decision["runID"] as? String
                    }
                    if let calls = value["toolCalls"] as? [[String: Any]],
                        calls.contains(where: { $0["state"] as? String == "received" })
                    {
                        preview.metadata["toolsPending"] = "true"
                    }
                }
                return preview
            }
        }
    }
    public func messageEvidence(_ id: String) throws -> [MessageRecord] {
        let key = try BusinessRecordID.number(id, kind: .message)
        return try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT dialog_id,client_id,input_id FROM messages WHERE id=?", arguments: [key])
            else { throw RecordStorageError.missingRecord }
            let dialog: Int64 = row["dialog_id"]
            let client: String = row["client_id"]
            let input: String = row["input_id"]
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT m.*,e.data FROM messages m JOIN evidence e ON e.hash=m.detail_hash
                    WHERE m.dialog_id=? AND ((m.client_id=? AND m.kind='input') OR m.client_id=?) ORDER BY m.id
                    """, arguments: [dialog, input, client]
            ).map { row in
                let task: Int64? = row["task_id"]
                return MessageRecord(
                    clientID: row["client_id"], inputID: row["input_id"], role: row["role"], kind: row["kind"],
                    order: UInt64(row["position"] as Int64), date: Date(timeIntervalSince1970: row["created_at"]),
                    body: row["body"],
                    state: row["state"], taskID: task.map { SQLiteRecordKey.id(.task, $0) },
                    detail: try Self.unpackDetail(row["data"], in: db),
                    id: SQLiteRecordKey.id(.message, row["id"]))
            }
        }
    }
    public func taskSources(_ id: String) throws -> [TaskSourceRecord] {
        let key = try BusinessRecordID.number(id, kind: .task)
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql:
                    "SELECT m.input_id,m.client_id,m.position FROM task_messages s JOIN messages m ON m.id=s.message_id WHERE s.task_id=? AND m.role='assistant' ORDER BY m.position LIMIT 8193",
                arguments: [key])
            guard rows.count <= 8192 else { throw RecordStorageError.invalidRecord }
            return rows.map {
                TaskSourceRecord(
                    inputID: $0["input_id"], requestID: $0["client_id"], position: UInt64($0["position"] as Int64))
            }
        }
    }
    public func latestPreviews(dialog id: String, limit: Int = 10) throws -> [MessagePreview] {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        return try database.read { db in
            let ids = try Int64.fetchAll(
                db,
                sql: """
                    SELECT m.id FROM messages m LEFT JOIN tasks t ON t.id=m.task_id
                    WHERE m.dialog_id=? AND m.role='assistant' AND (t.compression_hash IS NULL OR m.position=t.first_position)
                    ORDER BY m.position DESC LIMIT ?
                    """, arguments: [key, limit])
            return try ids.reversed().compactMap { rowID in
                guard
                    let row = try Row.fetchOne(
                        db, sql: "SELECT client_id,input_id,position,created_at,state,task_id FROM messages WHERE id=?",
                        arguments: [rowID])
                else { return nil }
                let task: Int64? = row["task_id"]
                return MessagePreview(
                    id: SQLiteRecordKey.id(.message, rowID), clientID: row["client_id"], inputID: row["input_id"],
                    input: "",
                    response: "",
                    date: Date(timeIntervalSince1970: row["created_at"]), position: UInt64(row["position"] as Int64),
                    state: row["state"], taskID: task.map { SQLiteRecordKey.id(.task, $0) }, isObservation: false,
                    isInput: false)
            }
        }
    }
    public func unfinishedUserMessages(dialog id: String) throws -> [MessageRecord] {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT m.*,e.data FROM messages m JOIN evidence e ON e.hash=m.detail_hash
                    WHERE m.dialog_id=? AND m.role='user' AND
                        ((m.kind='input' AND NOT EXISTS(SELECT 1 FROM messages a WHERE a.dialog_id=m.dialog_id AND a.input_id=m.client_id AND a.role='assistant'))
                        OR (m.kind='observation' AND NOT EXISTS(SELECT 1 FROM messages a WHERE a.dialog_id=m.dialog_id AND a.client_id=m.client_id AND a.role='assistant')))
                    ORDER BY m.position DESC LIMIT 32
                    """, arguments: [key]
            ).map { row in
                let task: Int64? = row["task_id"]
                return MessageRecord(
                    clientID: row["client_id"], inputID: row["input_id"], role: row["role"], kind: row["kind"],
                    order: UInt64(row["position"] as Int64), date: Date(timeIntervalSince1970: row["created_at"]),
                    body: row["body"], state: row["state"],
                    taskID: task.map { SQLiteRecordKey.id(.task, $0) },
                    detail: try Self.unpackDetail(row["data"], in: db),
                    id: SQLiteRecordKey.id(.message, row["id"]))
            }
        }
    }
    public func timelineCount(dialog id: String) throws -> Int {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        return try database.read { db in
            try Int.fetchOne(
                db,
                sql:
                    "SELECT COUNT(*) FROM messages m LEFT JOIN tasks t ON t.id=m.task_id WHERE m.dialog_id=? AND (m.role='assistant' OR (m.role='user' AND ((m.kind='input' AND NOT EXISTS(SELECT 1 FROM messages a WHERE a.dialog_id=m.dialog_id AND a.role='assistant' AND a.input_id=m.client_id)) OR (m.kind='observation' AND NOT EXISTS(SELECT 1 FROM messages a WHERE a.dialog_id=m.dialog_id AND a.role='assistant' AND a.client_id=m.client_id))))) AND (t.compression_hash IS NULL OR m.position=t.first_position)",
                arguments: [key]) ?? 0
        }
    }
    public func titleRows(dialog id: String, positions: [Int]) throws -> [MessagePreview] {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        guard positions.count <= 32, positions.allSatisfy({ $0 >= 0 }) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try positions.compactMap { offset in
                guard
                    let row = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT u.id,u.client_id,u.created_at,u.position,substr(u.preview,1,80) AS input,
                                COALESCE((SELECT substr(a.preview,1,80) FROM messages a WHERE a.dialog_id=u.dialog_id AND a.input_id=u.client_id AND a.role='assistant' ORDER BY a.position DESC LIMIT 1),'') AS response
                            FROM messages u WHERE u.dialog_id=? AND u.kind='input' ORDER BY u.position LIMIT 1 OFFSET ?
                            """, arguments: [key, offset])
                else { return nil }
                return MessagePreview(
                    id: SQLiteRecordKey.id(.message, row["id"]), clientID: row["client_id"], inputID: row["client_id"],
                    input: row["input"], response: row["response"],
                    date: Date(timeIntervalSince1970: row["created_at"]), position: UInt64(row["position"] as Int64),
                    state: "completed", taskID: nil, isObservation: false, isInput: false)
            }
        }
    }
    public func dialogForInput(_ input: String) throws -> String? {
        try database.read { db in
            let matches = try Int64.fetchAll(
                db, sql: "SELECT DISTINCT dialog_id FROM messages WHERE input_id=? LIMIT 2", arguments: [input])
            guard matches.count <= 1 else { throw RecordStorageError.invalidRecord }
            return matches.first.map { SQLiteRecordKey.id(.dialog, $0) }
        }
    }
    public func inputRows(_ input: String, dialog id: String) throws -> [MessageRecord] {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT m.*,e.data FROM messages m JOIN evidence e ON e.hash=m.detail_hash WHERE m.dialog_id=? AND m.input_id=? ORDER BY m.position,m.id",
                arguments: [key, input]
            ).map { row in
                let task: Int64? = row["task_id"]
                return MessageRecord(
                    clientID: row["client_id"], inputID: row["input_id"], role: row["role"], kind: row["kind"],
                    order: UInt64(row["position"] as Int64), date: Date(timeIntervalSince1970: row["created_at"]),
                    body: row["body"], state: row["state"], taskID: task.map { SQLiteRecordKey.id(.task, $0) },
                    detail: try Self.unpackDetail(row["data"], in: db), id: SQLiteRecordKey.id(.message, row["id"]))
            }
        }
    }
    public func dialogForMessage(_ id: String) throws -> String {
        let key = try BusinessRecordID.number(id, kind: .message)
        return try database.read { db in
            guard
                let dialog = try Int64.fetchOne(db, sql: "SELECT dialog_id FROM messages WHERE id=?", arguments: [key])
            else { throw RecordStorageError.missingRecord }
            return SQLiteRecordKey.id(.dialog, dialog)
        }
    }
    private static func blob(_ data: Data, in db: Database) throws -> String {
        let hash = ContentFingerprint.digest(data).map { String(format: "%02x", $0) }.joined()
        try db.execute(sql: "INSERT OR IGNORE INTO evidence(hash,data) VALUES(?,?)", arguments: [hash, data])
        return hash
    }
    private static let emptyDetailHash = ContentFingerprint.digest(Data()).map { String(format: "%02x", $0) }.joined()
    private static func mediaReferences(_ value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            var result: Set<String> = []
            for (key, value) in dictionary {
                if key == "mediaID" || key == "id", let id = value as? String, id.hasPrefix("media_") {
                    result.insert(id)
                }
                result.formUnion(mediaReferences(value))
            }
            return result
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(mediaReferences($1)) }
        }
        if let string = value as? String, let bytes = string.data(using: .utf8),
            let nested = try? JSONSerialization.jsonObject(with: bytes)
        {
            return mediaReferences(nested)
        }
        return []
    }
    private static func previewSQL(task: Bool) -> String {
        let filter = task ? "AND m.task_id=?" : "AND (t.compression_hash IS NULL OR m.position=t.first_position)"
        return """
            SELECT m.id,m.client_id,m.input_id,m.position,m.created_at,m.state,m.task_id,m.role,e.data AS preview_metadata,
                (SELECT COUNT(*) FROM messages r WHERE r.dialog_id=m.dialog_id AND r.kind='response' AND r.position<=m.position) AS ordinal,CASE WHEN m.role='user' THEN '' ELSE m.preview END AS response,
                CASE WHEN m.role='user' THEN m.preview ELSE COALESCE((SELECT o.preview FROM messages o WHERE o.dialog_id=m.dialog_id AND o.client_id=m.client_id AND o.role='user' AND o.kind='observation'),
                    (SELECT u.preview FROM messages u WHERE u.dialog_id=m.dialog_id AND u.client_id=m.input_id AND u.role='user' AND u.kind='input'),'') END AS input,
                EXISTS(SELECT 1 FROM messages o WHERE o.dialog_id=m.dialog_id AND o.client_id=m.client_id AND o.role='user' AND o.kind='observation') AS observation
            FROM messages m JOIN evidence e ON e.hash=m.detail_hash LEFT JOIN tasks t ON t.id=m.task_id WHERE m.dialog_id=? AND (m.role='assistant' OR (m.role='user' AND ((m.kind='input' AND NOT EXISTS(SELECT 1 FROM messages a WHERE a.dialog_id=m.dialog_id AND a.role='assistant' AND a.input_id=m.client_id)) OR (m.kind='observation' AND NOT EXISTS(SELECT 1 FROM messages a WHERE a.dialog_id=m.dialog_id AND a.role='assistant' AND a.client_id=m.client_id))))) AND m.position>? \(filter)
            ORDER BY m.position,m.id LIMIT ? OFFSET ?
            """
    }
    private static func packDetail(_ data: Data, in db: Database) throws -> String {
        let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        var references: Set<String> = []
        func pack(_ node: Any) throws -> Any {
            if let text = node as? String, text.utf8.count >= 4096 {
                let bytes = Data(text.utf8)
                var chunks: [String] = []
                for offset in stride(from: 0, to: bytes.count, by: 4096) {
                    let hash = try blob(bytes.subdata(in: offset..<min(bytes.count, offset + 4096)), in: db)
                    chunks.append(hash)
                    references.insert(hash)
                }
                return ["_textChunks": chunks, "_byteCount": bytes.count] as [String: Any]
            }
            if let object = node as? [String: Any] { return try object.mapValues(pack) }
            if let array = node as? [Any] { return try array.map(pack) }
            return node
        }
        let packed = try pack(value)
        let envelope: [String: Any] = ["codec": 1, "value": packed]
        let encoded = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        let hash = try blob(encoded, in: db)
        for child in references {
            try db.execute(sql: "INSERT OR IGNORE INTO evidence_refs VALUES(?,?)", arguments: [hash, child])
        }
        return hash
    }
    private static func unpackDetail(_ data: Data, in db: Database) throws -> Data {
        if data.isEmpty { return data }  // Reserved identity has no content/evidence yet.
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            envelope["codec"] as? Int == 1, let value = envelope["value"]
        else { throw RecordStorageError.invalidRecord }
        func unpack(_ node: Any) throws -> Any {
            if let object = node as? [String: Any] {
                if let chunks = object["_textChunks"] as? [String], let size = object["_byteCount"] as? Int,
                    object.count == 2
                {
                    guard size >= 0, size <= 32 * 1024 * 1024, chunks.count <= 8192 else {
                        throw RecordStorageError.invalidRecord
                    }
                    var bytes = Data()
                    bytes.reserveCapacity(size)
                    for hash in chunks {
                        guard
                            let part = try Data.fetchOne(
                                db, sql: "SELECT data FROM evidence WHERE hash=?", arguments: [hash]),
                            part.count <= 4096
                        else { throw RecordStorageError.missingRecord }
                        bytes.append(part)
                        guard bytes.count <= size else { throw RecordStorageError.invalidRecord }
                    }
                    guard bytes.count == size, let text = String(data: bytes, encoding: .utf8) else {
                        throw RecordStorageError.invalidRecord
                    }
                    return text
                }
                return try object.mapValues(unpack)
            }
            if let array = node as? [Any] { return try array.map(unpack) }
            return node
        }
        return try JSONSerialization.data(withJSONObject: unpack(value), options: [.sortedKeys, .fragmentsAllowed])
    }
    public func storageStatistics() throws -> (messages: Int, evidenceBytes: Int, sharedChunks: Int) {
        try database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(data)),0) FROM evidence") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT child_hash) FROM evidence_refs") ?? 0
            )
        }
    }
    func previewQueryPlan(dialog id: String, after: UInt64, taskID: String? = nil) throws -> [String] {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        let task = try taskID.map { try BusinessRecordID.number($0, kind: .task) }
        guard after <= Int64.max else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN " + Self.previewSQL(task: task != nil),
                arguments: StatementArguments(
                    [key, Int64(after)] + (task.map { [$0] } ?? []) + [Int64(HistoryPaging.pageSize), 0])
            )
            .map { $0["detail"] as String }
        }
    }
    private static let dialogMetadataColumns =
        "id,agent,created_at,archived_at,title,title_error,revision,input_count,latest_input,NULL AS recovery"
    internal func recoverInFlight() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE messages SET state='interrupted' WHERE state='generating'")
            for task in try Row.fetchAll(
                db,
                sql:
                    "SELECT id,dialog_id,goal,failure,finished_at FROM tasks WHERE status='interrupted' AND compression_hash IS NULL AND dialog_id IS NOT NULL"
            ) {
                let taskID: Int64 = task["id"]
                let sources = try Row.fetchAll(
                    db,
                    sql:
                        "SELECT input_id,client_id FROM messages WHERE task_id=? AND role='assistant' ORDER BY position,id",
                    arguments: [taskID])
                guard !sources.isEmpty else { continue }
                let compression = ConversationTaskCompression(
                    taskID: SQLiteRecordKey.id(.task, taskID), goal: task["goal"], status: .interrupted,
                    reportedSummary: nil, failure: task["failure"],
                    completedAt: Date(timeIntervalSince1970: task["finished_at"]),
                    sources: sources.map { .init(inputID: $0["input_id"], requestID: $0["client_id"]) })
                let hash = try Self.blob(JSONEncoder().encode(compression), in: db)
                try db.execute(
                    sql:
                        "UPDATE tasks SET compression_hash=?,first_position=(SELECT MIN(position) FROM messages WHERE task_id=? AND role='assistant') WHERE id=?",
                    arguments: [hash, taskID, taskID])
            }
        }
    }
}

/// Private ORM mapping. Stored records never escape the SQLite backend.
private struct SQLiteMessageRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "messages"
    var id: Int64?
    var dialogID: Int64
    var clientID: String
    var inputID: String
    var role: String
    var kind: String
    var position: Int64
    var createdAt: Double
    var body: String
    var preview: String
    var state: String
    var replyToMessageID: Int64?
    var taskID: Int64?
    var detailHash: String
    enum CodingKeys: String, CodingKey {
        case id, role, kind, position, body, preview, state
        case dialogID = "dialog_id"
        case clientID = "client_id"
        case inputID = "input_id"
        case createdAt = "created_at"
        case replyToMessageID = "reply_to_message_id"
        case taskID = "task_id"
        case detailHash = "detail_hash"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    func requireID() throws -> Int64 {
        guard let id else { throw RecordStorageError.invalidRecord }
        return id
    }
}

private struct SQLiteDialogRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "dialogs"
    var id: Int64?
    var agent: String
    var createdAt: Double
    var archivedAt: Double? = nil
    enum CodingKeys: String, CodingKey {
        case id, agent
        case createdAt = "created_at"
        case archivedAt = "archived_at"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
