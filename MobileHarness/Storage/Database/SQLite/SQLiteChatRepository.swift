import Foundation
internal import GRDB
import StorageChat
import StorageCore

/// Shared round storage with independently addressable model-request evidence.
public final class SQLiteChatRepository: ChatRepository {
    public var storageScope: UUID { database.storageScope }
    private let database: SQLiteDatabase
    internal init(database: SQLiteDatabase) { self.database = database }
    internal static let schemaSQL = """
        CREATE TABLE assistant_conversations(id INTEGER PRIMARY KEY AUTOINCREMENT,
          identity TEXT NOT NULL UNIQUE,agent TEXT NOT NULL,created_at REAL NOT NULL,archived_at REAL,
          title TEXT,title_error TEXT,revision INTEGER NOT NULL DEFAULT 0,input_count INTEGER NOT NULL DEFAULT 0,
          latest_input TEXT,recovery BLOB);
        CREATE UNIQUE INDEX current_conversation ON assistant_conversations(agent) WHERE archived_at IS NULL;
        CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT,
          conversation_id INTEGER REFERENCES assistant_conversations(id) ON DELETE CASCADE,
          writer_task_id INTEGER REFERENCES writer_tasks(id) ON DELETE CASCADE,
          client_id TEXT NOT NULL,input_id TEXT NOT NULL,segment TEXT NOT NULL DEFAULT '',
          task_id INTEGER REFERENCES assistant_tasks(id) ON DELETE SET NULL,position INTEGER NOT NULL,
          created_at REAL NOT NULL,user_text TEXT NOT NULL DEFAULT '',response_text TEXT NOT NULL DEFAULT '',
          state TEXT NOT NULL DEFAULT 'generating',detail_json TEXT NOT NULL DEFAULT '',
          CHECK((conversation_id IS NULL)!=(writer_task_id IS NULL)));
        CREATE UNIQUE INDEX conversation_round ON messages(conversation_id,client_id,segment) WHERE conversation_id IS NOT NULL;
        CREATE UNIQUE INDEX writer_round ON messages(writer_task_id,client_id,segment) WHERE writer_task_id IS NOT NULL;
        CREATE INDEX message_order ON messages(conversation_id,position,id);
        CREATE INDEX writer_message_order ON messages(writer_task_id,position,id);
        CREATE INDEX message_input ON messages(input_id);
        CREATE INDEX message_task ON messages(task_id,position);
        CREATE TABLE model_request_log(id INTEGER PRIMARY KEY AUTOINCREMENT,request_id TEXT NOT NULL UNIQUE,
          message_id INTEGER REFERENCES messages(id) ON DELETE CASCADE,
          conversation_id INTEGER REFERENCES assistant_conversations(id) ON DELETE CASCADE,
          delegate_id TEXT REFERENCES agent_delegations(delegate_id) ON DELETE SET NULL,agent TEXT NOT NULL,
          purpose TEXT NOT NULL DEFAULT 'generation',position INTEGER NOT NULL,created_at REAL NOT NULL,
          input_text TEXT NOT NULL DEFAULT '',response_text TEXT NOT NULL DEFAULT '',state TEXT NOT NULL DEFAULT 'generating',
          request_json TEXT NOT NULL DEFAULT '',detail_json TEXT NOT NULL DEFAULT '',preview_json TEXT NOT NULL DEFAULT '{}',
          CHECK((message_id IS NOT NULL AND conversation_id IS NULL AND purpose='generation') OR
                (message_id IS NULL AND conversation_id IS NOT NULL AND purpose='title')));
        CREATE INDEX request_message ON model_request_log(message_id,position,id);
        CREATE INDEX request_order ON model_request_log(position,id);
        CREATE INDEX request_delegation ON model_request_log(delegate_id,id);
        CREATE TABLE message_media(id INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id INTEGER REFERENCES messages(id) ON DELETE CASCADE,
          request_id INTEGER REFERENCES model_request_log(id) ON DELETE CASCADE,
          media_id INTEGER NOT NULL REFERENCES media_files(id),
          CHECK((message_id IS NULL)!=(request_id IS NULL)));
        CREATE UNIQUE INDEX message_media_link ON message_media(message_id,media_id) WHERE message_id IS NOT NULL;
        CREATE UNIQUE INDEX request_media_link ON message_media(request_id,media_id) WHERE request_id IS NOT NULL;
        """
    private struct Owner {
        let column: String
        let key: Int64
        let agent: String
    }
    private static func owner(_ id: String, db: Database) throws -> Owner {
        if let workspace = WorkspaceID(rawValue: id) {
            guard
                let key = try Int64.fetchOne(
                    db, sql: "SELECT id FROM writer_tasks WHERE agent=? AND number=?",
                    arguments: [workspace.agent, try BusinessRecordID.number(workspace.taskID, kind: .task)])
            else { throw RecordStorageError.missingRecord }
            return Owner(column: "writer_task_id", key: key, agent: workspace.agent)
        }
        let key = try BusinessRecordID.number(id, kind: .dialog)
        guard
            let agent = try String.fetchOne(
                db, sql: "SELECT agent FROM assistant_conversations WHERE id=?", arguments: [key])
        else { throw RecordStorageError.missingRecord }
        return Owner(column: "conversation_id", key: key, agent: agent)
    }
    private static func dialogID(_ row: Row, db: Database) throws -> String {
        if let key: Int64 = row["conversation_id"] { return SQLiteRecordKey.id(.dialog, key) }
        guard let key: Int64 = row["writer_task_id"],
            let task = try Row.fetchOne(db, sql: "SELECT agent,number FROM writer_tasks WHERE id=?", arguments: [key])
        else { throw RecordStorageError.missingRecord }
        return "\(task["agent"] as String)/task_\(task["number"] as Int64)"
    }
    private static func metadata(_ row: Row, recovery: Bool = true) throws -> DialogRecord {
        guard let identity = UUID(uuidString: row["identity"]) else { throw RecordStorageError.invalidRecord }
        let archived: Double? = row["archived_at"]
        return DialogRecord(
            id: SQLiteRecordKey.id(.dialog, row["id"]), agent: row["agent"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            archivedAt: archived.map(Date.init(timeIntervalSince1970:)),
            title: row["title"], titleError: row["title_error"], revision: UInt64(row["revision"] as Int64),
            recovery: recovery ? row["recovery"] : nil, count: row["input_count"], latestUser: row["latest_input"],
            traceID: identity)
    }
    public func saveAuxiliaryRequest(dialog id: String, request: ConversationModelRequest) throws {
        let conversation = try BusinessRecordID.number(id, kind: .dialog)
        try database.write { db in
            guard
                let agent = try String.fetchOne(
                    db, sql: "SELECT agent FROM assistant_conversations WHERE id=?", arguments: [conversation])
            else { throw RecordStorageError.missingRecord }
            let detail = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            try db.execute(
                sql:
                    "INSERT INTO model_request_log(request_id,conversation_id,agent,purpose,position,created_at,input_text,response_text,state,request_json,detail_json) VALUES(?,?,?,'title',0,?,?,?,?,?,?) ON CONFLICT(request_id) DO UPDATE SET response_text=excluded.response_text,state=excluded.state,request_json=excluded.request_json,detail_json=excluded.detail_json WHERE model_request_log.conversation_id=excluded.conversation_id AND model_request_log.purpose='title'",
                arguments: [
                    request.id, conversation, agent, request.date.timeIntervalSince1970, request.input,
                    request.response, request.state.rawValue, request.requestParametersJSON ?? request.requestJSON,
                    detail,
                ])
            guard db.changesCount == 1 else { throw RecordStorageError.conflict }
        }
    }
    public func current(agent: String, includingRecovery: Bool = true) throws -> DialogRecord {
        if let writer = try database.read({ db in
            try Row.fetchOne(
                db,
                sql:
                    "SELECT agent,number FROM writer_tasks WHERE agent=? AND current_delegate_id IS NOT NULL ORDER BY updated_at DESC,id DESC LIMIT 1",
                arguments: [agent])
        }) {
            return try dialog("\(agent)/task_\(writer["number"] as Int64)", includingRecovery: includingRecovery)
        }
        guard agent != "writer" else { throw RecordStorageError.missingRecord }
        if let existing = try database.read({ db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM assistant_conversations WHERE agent=? AND archived_at IS NULL",
                arguments: [agent])
        }) {
            return try Self.metadata(existing, recovery: includingRecovery)
        }
        return try database.write { db in
            if try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM assistant_conversations WHERE agent=? AND archived_at IS NULL",
                arguments: [agent]) == 0
            {
                try db.execute(
                    sql: "INSERT INTO assistant_conversations(identity,agent,created_at) VALUES(?,?,?)",
                    arguments: [UUID().uuidString, agent, Date().timeIntervalSince1970])
            }
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM assistant_conversations WHERE agent=? AND archived_at IS NULL",
                    arguments: [agent])
            else { throw RecordStorageError.missingRecord }
            return try Self.metadata(row, recovery: includingRecovery)
        }
    }
    public func dialog(_ id: String, includingRecovery: Bool = true) throws -> DialogRecord {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            if owner.column == "conversation_id" {
                guard
                    let row = try Row.fetchOne(
                        db, sql: "SELECT * FROM assistant_conversations WHERE id=?", arguments: [owner.key])
                else { throw RecordStorageError.missingRecord }
                return try Self.metadata(row, recovery: includingRecovery)
            }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM writer_tasks WHERE id=?", arguments: [owner.key]),
                let identity = UUID(uuidString: row["identity"])
            else { throw RecordStorageError.missingRecord }
            return DialogRecord(
                id: id, agent: owner.agent, createdAt: Date(timeIntervalSince1970: row["created_at"]),
                archivedAt: nil, title: row["goal"], titleError: nil,
                revision: UInt64(row["history_revision"] as Int64),
                recovery: nil,
                count: try Int.fetchOne(
                    db, sql: "SELECT COUNT(DISTINCT input_id) FROM messages WHERE writer_task_id=?",
                    arguments: [owner.key]) ?? 0,
                latestUser: try String.fetchOne(
                    db, sql: "SELECT user_text FROM messages WHERE writer_task_id=? ORDER BY position DESC LIMIT 1",
                    arguments: [owner.key]), traceID: identity)
        }
    }
    public func listDialogs(agent: String, before: Int64? = nil, limit: Int = HistoryPaging.pageSize) throws
        -> [DialogRecord]
    {
        guard (1...50).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM assistant_conversations WHERE agent=? AND archived_at IS NOT NULL AND id<? ORDER BY id DESC LIMIT ?",
                arguments: [agent, before ?? Int64.max, limit]
            ).map { try Self.metadata($0, recovery: false) }
        }
    }
    private static func round(
        owner: Owner, client: String, input: String, task: String?, position: UInt64, date: Date,
        allowArchived: Bool = false, db: Database
    ) throws -> Int64 {
        guard position <= Int64.max else { throw RecordStorageError.invalidRecord }
        if task == nil && client == input,
            let existing = try Int64.fetchOne(
                db, sql: "SELECT id FROM messages WHERE \(owner.column)=? AND input_id=? ORDER BY id LIMIT 1",
                arguments: [owner.key, input])
        {
            return existing
        }
        let segment = owner.column == "conversation_id" ? task ?? "" : ""
        if let existing = try Int64.fetchOne(
            db, sql: "SELECT id FROM messages WHERE \(owner.column)=? AND client_id=? AND segment=?",
            arguments: [owner.key, input, segment])
        {
            return existing
        }
        let taskKey =
            owner.column == "conversation_id" ? try task.map { try BusinessRecordID.number($0, kind: .task) } : nil
        if let taskKey,
            let base = try Row.fetchOne(
                db,
                sql:
                    "SELECT id FROM messages WHERE conversation_id=? AND client_id=? AND segment='' AND NOT EXISTS(SELECT 1 FROM model_request_log WHERE message_id=messages.id)",
                arguments: [owner.key, input])
        {
            let key: Int64 = base["id"]
            try db.execute(
                sql: "UPDATE messages SET segment=?,task_id=? WHERE id=?", arguments: [segment, taskKey, key])
            return key
        }
        if owner.column == "conversation_id", !allowArchived,
            try Double.fetchOne(
                db, sql: "SELECT archived_at FROM assistant_conversations WHERE id=?", arguments: [owner.key]) != nil
        {
            throw RecordStorageError.conflict
        }
        // Segments retain the same original input. Only the first one owns the admission counter.
        let original = try Row.fetchOne(
            db,
            sql:
                "SELECT user_text,detail_json FROM messages WHERE \(owner.column)=? AND input_id=? ORDER BY id LIMIT 1",
            arguments: [owner.key, input])
        try db.execute(
            sql:
                "INSERT INTO messages(\(owner.column),client_id,input_id,segment,task_id,position,created_at,user_text,detail_json) VALUES(?,?,?,?,?,?,?,?,?)",
            arguments: [
                owner.key, input, input, segment, taskKey, Int64(position), date.timeIntervalSince1970,
                original?["user_text"] as String? ?? "", original?["detail_json"] as String? ?? "",
            ])
        return db.lastInsertedRowID
    }
    /// A request is reserved before Actions run. startTask may attach that same request later.
    private static func requestRound(
        owner: Owner, client: String, input: String, task: String?, position: UInt64, date: Date, db: Database
    ) throws -> Int64 {
        guard
            let original = try Row.fetchOne(
                db,
                sql: "SELECT m.* FROM model_request_log r JOIN messages m ON m.id=r.message_id WHERE r.request_id=?",
                arguments: [client])
        else {
            return try round(
                owner: owner, client: client, input: input, task: task, position: position, date: date, db: db)
        }
        guard original[owner.column] as Int64? == owner.key, original["input_id"] as String == input else {
            throw RecordStorageError.conflict
        }
        let previous: Int64 = original["id"]
        let existingTask: Int64? = original["task_id"]
        let desiredTask =
            owner.column == "conversation_id" ? try task.map { try BusinessRecordID.number($0, kind: .task) } : nil
        if existingTask == desiredTask { return previous }
        guard existingTask == nil, let desiredTask,
            let targetTask = try Row.fetchOne(
                db, sql: "SELECT dialog_id FROM assistant_tasks WHERE id=? AND agent=?",
                arguments: [desiredTask, owner.agent]),
            (targetTask["dialog_id"] as Int64?).map({ $0 == owner.key }) ?? true
        else { throw RecordStorageError.conflict }
        try db.execute(
            sql:
                "UPDATE assistant_tasks SET dialog_id=COALESCE(dialog_id,?),source_revision=source_revision+1 WHERE id=?",
            arguments: [owner.key, desiredTask])
        let segment = task ?? ""
        let destination = try Int64.fetchOne(
            db, sql: "SELECT id FROM messages WHERE conversation_id=? AND input_id=? AND segment=?",
            arguments: [owner.key, input, segment])
        let count =
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM model_request_log WHERE message_id=?", arguments: [previous]) ?? 0
        if destination == nil && count == 1 {
            try db.execute(
                sql: "UPDATE messages SET task_id=?,segment=? WHERE id=?", arguments: [desiredTask, segment, previous])
            return previous
        }
        let next =
            try destination
            ?? round(
                owner: owner, client: client, input: input, task: task, position: position, date: date,
                allowArchived: true, db: db)
        try db.execute(
            sql: "UPDATE model_request_log SET message_id=? WHERE request_id=? AND message_id=?",
            arguments: [next, client, previous])
        guard db.changesCount == 1 else { throw RecordStorageError.conflict }
        try db.execute(
            sql:
                "INSERT OR IGNORE INTO message_media(message_id,media_id) SELECT ?,media_id FROM message_media WHERE message_id=?",
            arguments: [next, previous])
        try refreshRound(previous, db: db)
        try refreshRound(next, db: db)
        return next
    }
    private static func refreshRound(_ id: Int64, db: Database) throws {
        try db.execute(
            sql:
                "UPDATE messages SET response_text=(SELECT COALESCE(group_concat(response_text,''),'') FROM (SELECT response_text FROM model_request_log WHERE message_id=? ORDER BY position,id)),state=COALESCE((SELECT state FROM model_request_log WHERE message_id=? ORDER BY position DESC,id DESC LIMIT 1),'completed') WHERE id=?",
            arguments: [id, id, id])
    }
    private static let hasInputRequest =
        "EXISTS(SELECT 1 FROM model_request_log r JOIN messages z ON z.id=r.message_id WHERE z.conversation_id IS m.conversation_id AND z.writer_task_id IS m.writer_task_id AND z.input_id=m.input_id)"
    public func beginMessage(dialog id: String, identity: MessageIdentity) throws -> String {
        try database.write { db in
            let owner = try Self.owner(id, db: db)
            let round: Int64
            if identity.kind == "input" {
                round = try Self.round(
                    owner: owner, client: identity.clientID, input: identity.inputID, task: identity.taskID,
                    position: identity.order, date: identity.date, db: db)
            } else {
                round = try Self.requestRound(
                    owner: owner, client: identity.clientID, input: identity.inputID, task: identity.taskID,
                    position: identity.order, date: identity.date, db: db)
            }
            if identity.role == "user" && identity.kind == "input" { return SQLiteRecordKey.id(.message, round) }
            guard identity.role == "assistant" || identity.kind == "observation" else {
                throw RecordStorageError.invalidRecord
            }
            try db.execute(
                sql:
                    "INSERT OR IGNORE INTO model_request_log(request_id,message_id,agent,position,created_at) VALUES(?,?,?,?,?)",
                arguments: [
                    identity.clientID, round, owner.agent, Int64(identity.order), identity.date.timeIntervalSince1970,
                ])
            if db.changesCount == 1 {
                try db.execute(
                    sql:
                        "UPDATE assistant_tasks SET source_revision=source_revision+1 WHERE id=(SELECT task_id FROM messages WHERE id=?)",
                    arguments: [round])
            }
            guard
                let key = try Int64.fetchOne(
                    db, sql: "SELECT id FROM model_request_log WHERE request_id=? AND message_id=?",
                    arguments: [identity.clientID, round])
            else { throw RecordStorageError.conflict }
            if let detail = identity.detail {
                let header = try JSONSerialization.jsonObject(with: detail) as? [String: Any]
                try db.execute(
                    sql: "UPDATE model_request_log SET request_json=?,detail_json=? WHERE id=? AND detail_json=''",
                    arguments: [header?["requestJSON"] as? String ?? "", String(decoding: detail, as: UTF8.self), key])
            }
            return SQLiteRecordKey.id(.request, key)
        }
    }
    @discardableResult public func save(
        dialog id: String, revision: UInt64, recovery: Data?, messages: [MessageRecord],
        summaries: [TaskCompressionRecord]
    ) throws -> [MessageReference] {
        try database.write { db in
            let owner = try Self.owner(id, db: db)
            var references: [MessageReference] = []
            for message in messages {
                let round: Int64
                if message.kind == "input" {
                    round = try Self.round(
                        owner: owner, client: message.clientID, input: message.inputID, task: message.taskID,
                        position: message.order, date: message.date, db: db)
                } else {
                    round = try Self.requestRound(
                        owner: owner, client: message.clientID, input: message.inputID, task: message.taskID,
                        position: message.order, date: message.date, db: db)
                }
                let detail = String(decoding: message.detail, as: UTF8.self)
                if message.kind == "input" {
                    let hadInput =
                        try Int.fetchOne(
                            db,
                            sql:
                                "SELECT COUNT(*) FROM messages WHERE \(owner.column)=? AND input_id=? AND detail_json!=''",
                            arguments: [owner.key, message.inputID]) ?? 0
                    try db.execute(
                        sql:
                            "UPDATE messages SET user_text=?,detail_json=?,state=CASE WHEN NOT EXISTS(SELECT 1 FROM model_request_log WHERE message_id=messages.id) THEN ? ELSE state END WHERE \(owner.column)=? AND input_id=?",
                        arguments: [message.body, detail, message.state, owner.key, message.inputID])
                    if hadInput == 0 && owner.column == "conversation_id" {
                        try db.execute(
                            sql:
                                "UPDATE assistant_conversations SET input_count=input_count+1,latest_input=? WHERE id=?",
                            arguments: [String(message.body.prefix(80)), owner.key])
                    }
                    references.append(
                        .init(id: SQLiteRecordKey.id(.message, round), clientID: message.clientID, role: message.role))
                    try Self.linkMedia(message.detail, message: round, request: nil, db: db)
                    continue
                }
                try db.execute(
                    sql:
                        "INSERT OR IGNORE INTO model_request_log(request_id,message_id,agent,position,created_at) VALUES(?,?,?,?,?)",
                    arguments: [
                        message.clientID, round, owner.agent, Int64(message.order), message.date.timeIntervalSince1970,
                    ])
                guard
                    let log = try Row.fetchOne(
                        db, sql: "SELECT * FROM model_request_log WHERE request_id=? AND message_id=?",
                        arguments: [message.clientID, round])
                else { throw RecordStorageError.conflict }
                let key: Int64 = log["id"]
                if message.kind == "observation" {
                    try db.execute(
                        sql: "UPDATE model_request_log SET input_text=? WHERE id=?", arguments: [message.body, key])
                } else {
                    let payload =
                        message.detail.isEmpty
                        ? nil : try JSONSerialization.jsonObject(with: message.detail) as? [String: Any]
                    let decision = payload?["decisionMetadata"] as? [String: Any]
                    let metadata = payload?["producerMetadata"] as? [String: String] ?? [:]
                    let delegate = decision?["delegateID"] as? String ?? metadata["delegateID"]
                    var preview: [String: Any] = [:]
                    preview["producerMetadata"] = payload?["producerMetadata"]
                    preview["decisionMetadata"] = decision.map {
                        ["mode": $0["mode"] ?? "", "delegateID": $0["delegateID"] ?? ""]
                    }
                    preview["toolCalls"] = (payload?["toolCalls"] as? [[String: Any]])?.map {
                        [
                            "name": $0["name"] ?? "", "argumentsJSON": $0["argumentsJSON"] ?? "",
                            "state": $0["state"] ?? "",
                        ]
                    }
                    let previewJSON = String(
                        decoding: try JSONSerialization.data(withJSONObject: preview), as: UTF8.self)
                    if log["detail_json"] as String != detail || log["response_text"] as String != message.body {
                        try db.execute(
                            sql:
                                "UPDATE assistant_tasks SET source_revision=source_revision+1 WHERE id=(SELECT task_id FROM messages WHERE id=?)",
                            arguments: [round])
                    }
                    try db.execute(
                        sql:
                            "UPDATE model_request_log SET delegate_id=?,input_text=CASE WHEN input_text='' THEN ? ELSE input_text END,response_text=?,state=?,request_json=?,detail_json=?,preview_json=? WHERE id=?",
                        arguments: [
                            delegate, payload?["input"] as? String ?? "", message.body, message.state,
                            payload?["requestParametersJSON"] as? String ?? payload?["requestJSON"] as? String ?? "",
                            detail, previewJSON, key,
                        ])
                    try Self.refreshRound(round, db: db)
                }
                references.append(
                    .init(id: SQLiteRecordKey.id(.request, key), clientID: message.clientID, role: message.role))
                try Self.linkMedia(message.detail, message: nil, request: key, db: db)
            }
            for summary in summaries {
                let task = try BusinessRecordID.number(summary.id, kind: .task)
                try db.execute(
                    sql:
                        "UPDATE assistant_tasks SET dialog_id=?,goal=?,status=?,summary=?,failure=?,finished_at=?,compression_json=?,summary_revision=source_revision,first_position=(SELECT MIN(r.position) FROM model_request_log r JOIN messages m ON m.id=r.message_id WHERE m.task_id=assistant_tasks.id) WHERE id=? AND agent=?",
                    arguments: [
                        owner.key, summary.goal, summary.status, summary.summary, summary.failure,
                        summary.finishedAt.timeIntervalSince1970, String(decoding: summary.detail, as: UTF8.self), task,
                        owner.agent,
                    ])
                guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
            }
            guard revision <= Int64.max else { throw RecordStorageError.invalidRecord }
            if owner.column == "conversation_id" {
                try db.execute(
                    sql: "UPDATE assistant_conversations SET revision=?,recovery=? WHERE id=?",
                    arguments: [Int64(revision), recovery, owner.key])
            } else {
                try db.execute(
                    sql: "UPDATE writer_tasks SET history_revision=? WHERE id=?",
                    arguments: [Int64(revision), owner.key])
            }
            return references
        }
    }
    private static func inputRecord(_ row: Row) -> MessageRecord {
        MessageRecord(
            clientID: row["client_id"], inputID: row["input_id"], role: "user", kind: "input",
            order: UInt64(row["position"] as Int64), date: Date(timeIntervalSince1970: row["created_at"]),
            body: row["user_text"],
            state: (row["detail_json"] as String).isEmpty && (row["user_text"] as String).isEmpty
                ? row["state"] : "completed", detail: Data((row["detail_json"] as String).utf8),
            id: SQLiteRecordKey.id(.message, row["id"]))
    }
    private static func records(_ row: Row, db: Database, request: Int64? = nil) throws -> [MessageRecord] {
        var result = [inputRecord(row)]
        let task: Int64? = row["task_id"]
        for log in try Row.fetchAll(
            db,
            sql:
                "SELECT * FROM model_request_log WHERE message_id=? \(request == nil ? "" : "AND id=?") ORDER BY position,id",
            arguments: StatementArguments([row["id"] as Int64])
                + (request.map { StatementArguments([$0]) } ?? StatementArguments()))
        {
            let id = SQLiteRecordKey.id(.request, log["id"])
            let input: String = log["input_text"]
            if !input.isEmpty {
                result.append(
                    MessageRecord(
                        clientID: log["request_id"], inputID: row["input_id"], role: "user", kind: "observation",
                        order: UInt64(log["position"] as Int64), date: Date(timeIntervalSince1970: log["created_at"]),
                        body: input, state: "completed", taskID: task.map { SQLiteRecordKey.id(.task, $0) },
                        detail: Data(), id: nil))
            }
            result.append(
                MessageRecord(
                    clientID: log["request_id"], inputID: row["input_id"], role: "assistant", kind: "response",
                    order: UInt64(log["position"] as Int64), date: Date(timeIntervalSince1970: log["created_at"]),
                    body: log["response_text"], state: log["state"], taskID: task.map { SQLiteRecordKey.id(.task, $0) },
                    detail: Data((log["detail_json"] as String).utf8), id: id))
        }
        if (row["detail_json"] as String).isEmpty && (row["user_text"] as String).isEmpty { result.removeFirst() }
        return result
    }
    public func messagePage(dialog id: String, after: Int64? = nil, limit: Int = 50) throws -> MessagePage {
        guard (1...50).contains(limit) else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            let owner = try Self.owner(id, db: db)
            var position: Int64 = -1
            if let after {
                guard
                    let found = try Int64.fetchOne(
                        db, sql: "SELECT position FROM messages WHERE id=? AND \(owner.column)=?",
                        arguments: [after, owner.key])
                else { throw RecordStorageError.missingRecord }
                position = found
            }
            let rows = try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM messages WHERE \(owner.column)=? AND (position,id)>(?,?) ORDER BY position,id LIMIT ?",
                arguments: [owner.key, position, after ?? 0, limit + 1])
            let page = Array(rows.prefix(limit))
            return MessagePage(
                records: try page.flatMap { try Self.records($0, db: db) },
                next: rows.count > limit ? page.last?["id"] : nil)
        }
    }
    public func messages(dialog id: String, after: Int64? = nil, limit: Int = 50) throws -> [MessageRecord] {
        try messagePage(dialog: id, after: after, limit: limit).records
    }
    private static let validSummary =
        "t.compression_json IS NOT NULL AND t.summary_revision=t.source_revision AND (COALESCE(t.summary,'')!='' OR COALESCE(t.failure,'')!='') AND t.status NOT IN ('running','finishing')"
    public func compressionData(dialog id: String, taskIDs: [String]? = nil) throws -> [Data] {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            guard owner.column == "conversation_id" else { return [] }
            let filter = try taskIDs.map { try $0.map { try BusinessRecordID.number($0, kind: .task) } }
            if filter?.isEmpty == true { return [] }
            let clause =
                filter.map { " AND t.id IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" }
                ?? ""
            return try String.fetchAll(
                db,
                sql: "SELECT t.compression_json FROM assistant_tasks t WHERE t.dialog_id=? AND (\(Self.validSummary))"
                    + clause + " ORDER BY t.id", arguments: StatementArguments([owner.key] + (filter ?? []))
            ).map { Data($0.utf8) }
        }
    }
    public func rotate(_ id: String, agent: String) throws -> DialogRecord {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        try database.write { db in
            try db.execute(
                sql: "UPDATE assistant_conversations SET archived_at=? WHERE id=? AND agent=? AND archived_at IS NULL",
                arguments: [Date().timeIntervalSince1970, key, agent])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
            try db.execute(
                sql: "INSERT INTO assistant_conversations(identity,agent,created_at) VALUES(?,?,?)",
                arguments: [UUID().uuidString, agent, Date().timeIntervalSince1970])
        }
        return try current(agent: agent)
    }
    public func setTitle(_ title: String?, error: String?, dialog id: String) throws {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        try database.write { db in
            try db.execute(
                sql: "UPDATE assistant_conversations SET title=?,title_error=? WHERE id=?",
                arguments: [title, error, key])
        }
    }
    public func deleteDialog(_ id: String) throws {
        let key = try BusinessRecordID.number(id, kind: .dialog)
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM assistant_conversations WHERE id=? AND archived_at IS NOT NULL", arguments: [key])
            guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
        }
    }
    private static func previewSQL(task: Bool) -> String {
        let filter = task ? "m.task_id=?" : "(NOT (\(validSummary)) OR r.position=t.first_position OR t.id IS NULL)"
        return """
            SELECT r.id,r.request_id,r.position,r.created_at,r.state,r.preview_json,substr(r.input_text,1,240) AS input_text,substr(r.response_text,1,240) AS response_text,m.input_id,substr(m.user_text,1,240) AS user_text,m.task_id,
            (SELECT COUNT(*) FROM model_request_log x JOIN messages z ON z.id=x.message_id WHERE z.conversation_id IS m.conversation_id AND z.writer_task_id IS m.writer_task_id AND x.position<=r.position) AS ordinal
            FROM model_request_log r INDEXED BY request_order JOIN messages m ON m.id=r.message_id LEFT JOIN assistant_tasks t ON t.id=m.task_id
            WHERE m.%@=? AND r.position>? AND \(filter) ORDER BY r.position,r.id LIMIT ? OFFSET ?
            """
    }
    public func previews(
        dialog id: String, after: UInt64 = 0, taskID: String? = nil, limit: Int = HistoryPaging.pageSize,
        offset: Int = 0
    ) throws -> [MessagePreview] {
        guard after <= Int64.max, (1...50).contains(limit), offset >= 0 else { throw RecordStorageError.invalidRecord }
        return try database.read { db in
            let owner = try Self.owner(id, db: db)
            let task = try taskID.map { try BusinessRecordID.number($0, kind: .task) }
            let sql = Self.previewSQL(task: task != nil).replacingOccurrences(of: "%@", with: owner.column)
            let rows = try Row.fetchAll(
                db, sql: sql,
                arguments: StatementArguments(
                    [owner.key, Int64(after)] + (task.map { [$0] } ?? []) + [Int64(limit + offset), 0]))
            var results = try rows.map { row in
                let task: Int64? = row["task_id"]
                let input: String = row["input_text"]
                var result = MessagePreview(
                    id: SQLiteRecordKey.id(.request, row["id"]), clientID: row["request_id"], inputID: row["input_id"],
                    input: String((input.isEmpty ? row["user_text"] as String : input).prefix(240)),
                    response: String((row["response_text"] as String).prefix(240)),
                    date: Date(timeIntervalSince1970: row["created_at"]), position: UInt64(row["position"] as Int64),
                    state: row["state"], taskID: task.map { SQLiteRecordKey.id(.task, $0) },
                    isObservation: !input.isEmpty, isInput: false)
                result.ordinal = row["ordinal"]
                if let metadata = try JSONSerialization.jsonObject(with: Data((row["preview_json"] as String).utf8))
                    as? [String: Any]
                {
                    result.metadata = metadata["producerMetadata"] as? [String: String] ?? [:]
                    if let decision = metadata["decisionMetadata"] as? [String: String] {
                        result.metadata["phase"] = decision["mode"]
                        result.metadata["delegateID"] = decision["delegateID"]
                    }
                    result.toolCalls = (metadata["toolCalls"] as? [[String: String]] ?? []).compactMap {
                        guard let name = $0["name"], let arguments = $0["argumentsJSON"] else { return nil }
                        return .init(name: name, argumentsJSON: arguments, state: $0["state"] ?? "received")
                    }
                    if result.toolCalls.contains(where: { $0.state == "received" }) {
                        result.metadata["toolsPending"] = "true"
                    }
                }
                return result
            }
            let pending = try Row.fetchAll(
                db,
                sql:
                    "SELECT id,client_id,input_id,substr(user_text,1,240) AS user_text,position,created_at,state,task_id FROM messages m WHERE \(owner.column)=? AND position>? AND NOT \(Self.hasInputRequest) \(task == nil ? "" : "AND task_id=?") ORDER BY position,id LIMIT ?",
                arguments: StatementArguments(
                    [owner.key, Int64(after)] + (task.map { [$0] } ?? []) + [Int64(limit + offset)]))
            results += pending.map { row in
                let key: Int64? = row["task_id"]
                return MessagePreview(
                    id: SQLiteRecordKey.id(.message, row["id"]), clientID: row["client_id"], inputID: row["input_id"],
                    input: row["user_text"], response: "", date: Date(timeIntervalSince1970: row["created_at"]),
                    position: UInt64(row["position"] as Int64), state: row["state"],
                    taskID: key.map { SQLiteRecordKey.id(.task, $0) }, isObservation: false, isInput: true)
            }
            return Array(results.sorted { ($0.position, $0.id) < ($1.position, $1.id) }.dropFirst(offset).prefix(limit))
        }
    }
    public func messageEvidence(_ id: String) throws -> [MessageRecord] {
        guard let key = BusinessRecordID(rawValue: id), [.message, .request].contains(key.kind) else {
            throw RecordStorageError.invalidID
        }
        return try database.read { db in
            let sql =
                key.kind == .message
                ? "SELECT * FROM messages WHERE id=?"
                : "SELECT m.* FROM messages m JOIN model_request_log r ON r.message_id=m.id WHERE r.id=?"
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [key.number]) else {
                throw RecordStorageError.missingRecord
            }
            return try Self.records(row, db: db, request: key.kind == .request ? key.number : nil)
        }
    }
    public func taskSources(_ id: String) throws -> [TaskSourceRecord] {
        let task = try BusinessRecordID.number(id, kind: .task)
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT m.input_id,r.request_id,r.position FROM model_request_log r JOIN messages m ON m.id=r.message_id WHERE m.task_id=? ORDER BY r.position,r.id",
                arguments: [task]
            ).map {
                .init(inputID: $0["input_id"], requestID: $0["request_id"], position: UInt64($0["position"] as Int64))
            }
        }
    }
    public func latestPreviews(dialog id: String, limit: Int = 10) throws -> [MessagePreview] {
        let count = try timelineCount(dialog: id)
        return try previews(dialog: id, limit: limit, offset: max(0, count - limit))
    }
    public func unfinishedUserMessages(dialog id: String) throws -> [MessageRecord] {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            return try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM messages m WHERE \(owner.column)=? AND NOT \(Self.hasInputRequest)",
                arguments: [owner.key]
            ).map(Self.inputRecord)
        }
    }
    public func timelineCount(dialog id: String) throws -> Int {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            let requests =
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM model_request_log r JOIN messages m ON m.id=r.message_id LEFT JOIN assistant_tasks t ON t.id=m.task_id WHERE m.\(owner.column)=? AND (t.id IS NULL OR NOT (\(Self.validSummary)) OR r.position=t.first_position)",
                    arguments: [owner.key]) ?? 0
            let pending =
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM messages m WHERE \(owner.column)=? AND NOT \(Self.hasInputRequest)",
                    arguments: [owner.key]) ?? 0
            return requests + pending
        }
    }
    public func titleRows(dialog id: String, positions: [Int]) throws -> [MessagePreview] {
        try positions.flatMap { try previews(dialog: id, limit: 1, offset: $0) }
    }
    public func dialogForInput(_ input: String) throws -> String? {
        try database.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT DISTINCT conversation_id,writer_task_id FROM messages WHERE input_id=? LIMIT 2",
                arguments: [input])
            guard rows.count <= 1 else { throw RecordStorageError.invalidRecord }
            return try rows.first.map { try Self.dialogID($0, db: db) }
        }
    }
    public func inputRows(_ input: String, dialog id: String) throws -> [MessageRecord] {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            return try Row.fetchAll(
                db, sql: "SELECT * FROM messages WHERE \(owner.column)=? AND input_id=? ORDER BY position,id",
                arguments: [owner.key, input]
            ).flatMap { try Self.records($0, db: db) }
        }
    }
    public func dialogForMessage(_ id: String) throws -> String {
        guard let key = BusinessRecordID(rawValue: id), [.message, .request].contains(key.kind) else {
            throw RecordStorageError.invalidID
        }
        return try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: key.kind == .message
                        ? "SELECT * FROM messages WHERE id=?"
                        : "SELECT m.* FROM messages m JOIN model_request_log r ON r.message_id=m.id WHERE r.id=?",
                    arguments: [key.number])
            else { throw RecordStorageError.missingRecord }
            return try Self.dialogID(row, db: db)
        }
    }
    private static func mediaReferences(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: Set<String>()) { result, pair in
                if ["mediaID", "id"].contains(pair.key), let raw = pair.value as? String,
                    BusinessRecordID(rawValue: raw)?.kind == .media
                {
                    result.insert(raw)
                }
                result.formUnion(mediaReferences(pair.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(mediaReferences($1)) }
        }
        if let text = value as? String, let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            return mediaReferences(nested)
        }
        return []
    }
    private static func linkMedia(_ detail: Data, message: Int64?, request: Int64?, db: Database) throws {
        guard !detail.isEmpty, let json = try? JSONSerialization.jsonObject(with: detail) else { return }
        for raw in mediaReferences(json) {
            let media = try BusinessRecordID.number(raw, kind: .media)
            try db.execute(
                sql:
                    "INSERT OR IGNORE INTO message_media(message_id,request_id,media_id) SELECT ?,?,id FROM media_files WHERE id=?",
                arguments: [message, request, media])
        }
    }
    public func storageStatistics() throws -> (messages: Int, requests: Int, requestLogBytes: Int) {
        try database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM model_request_log") ?? 0,
                try Int.fetchOne(
                    db, sql: "SELECT COALESCE(SUM(length(detail_json)+length(request_json)),0) FROM model_request_log")
                    ?? 0
            )
        }
    }
    func previewQueryPlan(dialog id: String, after: UInt64, taskID: String? = nil) throws -> [String] {
        try database.read { db in
            let owner = try Self.owner(id, db: db)
            let task = try taskID.map { try BusinessRecordID.number($0, kind: .task) }
            return try Row.fetchAll(
                db,
                sql: "EXPLAIN QUERY PLAN "
                    + Self.previewSQL(task: task != nil).replacingOccurrences(of: "%@", with: owner.column),
                arguments: StatementArguments([owner.key, Int64(after)] + (task.map { [$0] } ?? []) + [20, 0])
            ).map { $0["detail"] }
        }
    }
    internal func recoverInFlight() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE model_request_log SET state='interrupted' WHERE state='generating'")
            try db.execute(sql: "UPDATE messages SET state='interrupted' WHERE state='generating'")
            for task in try Row.fetchAll(
                db, sql: "SELECT * FROM assistant_tasks WHERE status='interrupted' AND compression_json IS NULL")
            {
                let key: Int64 = task["id"]
                let sources = try Row.fetchAll(
                    db,
                    sql:
                        "SELECT m.input_id,r.request_id,r.position FROM model_request_log r JOIN messages m ON m.id=r.message_id WHERE m.task_id=? ORDER BY r.position,r.id",
                    arguments: [key])
                guard !sources.isEmpty else { continue }
                let value = ConversationTaskCompression(
                    taskID: SQLiteRecordKey.id(.task, key), goal: task["goal"], status: .interrupted,
                    reportedSummary: nil, failure: task["failure"],
                    completedAt: Date(timeIntervalSince1970: task["finished_at"]),
                    sources: sources.map { .init(inputID: $0["input_id"], requestID: $0["request_id"]) })
                try db.execute(
                    sql:
                        "UPDATE assistant_tasks SET compression_json=?,summary_revision=source_revision,first_position=? WHERE id=?",
                    arguments: [
                        String(decoding: try JSONEncoder().encode(value), as: UTF8.self),
                        sources.first?["position"] as Int64?, key,
                    ])
            }

        }
    }
}
