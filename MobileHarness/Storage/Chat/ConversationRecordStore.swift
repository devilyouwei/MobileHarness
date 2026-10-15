import Foundation
import Storage
import StorageTasks

public struct ConversationCheckpoint: Sendable {
    public let version = 1
    public var conversation: StoredConversation
    public let revision: UInt64
    public let recovery: Data?
    public var changedInputs: Set<String>? = nil
    public init(conversation: StoredConversation, recovery: Data? = nil, revision: UInt64 = 0) {
        self.conversation = conversation
        self.recovery = recovery
        self.revision = revision
    }
}

/// SQL adapter for complete messages; no document/index/rotation persistence remains.
public actor ConversationRecordStore {
    internal nonisolated let repository: any ChatRepository
    public nonisolated let tasks: any TaskRepository
    public let agent: String
    public private(set) var checkpointCount = 0
    private let writeGate = StorageOperationGate()
    private var saved: [String: Data] = [:]
    private var savedSummaries: [String: Data] = [:]
    var cachedFingerprintCount: Int { saved.count + savedSummaries.count }
    public init(repository: any ChatRepository, tasks: any TaskRepository, agent: String = "assistant") throws {
        guard repository.storageScope == tasks.storageScope else { throw RecordStorageError.invalidRecord }
        self.repository = repository
        self.tasks = tasks
        self.agent = agent
    }
    private func ownedDialog(_ id: String) async throws -> DialogRecord {
        let row = try await repository.dialog(id, includingRecovery: false)
        guard row.agent == agent else { throw RecordStorageError.missingRecord }
        return row
    }
    private static func decodeInput(_ row: MessageRecord) throws -> ConversationRecord {
        if !row.detail.isEmpty { return try JSONDecoder().decode(ConversationRecord.self, from: row.detail) }
        var turn = ConversationRecord(
            id: row.clientID, date: row.date, user: row.body, request: [], model: "",
            maximumOutputTokens: nil, temperature: 0)
        turn.historyOrder = row.order
        turn.state = ConversationRecord.State(rawValue: row.state) ?? .interrupted
        return turn
    }
    private static func decodeResponse(_ row: MessageRecord) throws -> ConversationModelRequest {
        var request: ConversationModelRequest
        if row.detail.isEmpty {
            request = ConversationModelRequest(
                id: row.clientID, input: "", requestJSON: "[]", historyTaskID: row.taskID, date: row.date)
            request.historyOrder = row.order
        } else {
            request = try JSONDecoder().decode(ConversationModelRequest.self, from: row.detail)
        }
        request.state = ConversationRecord.State(rawValue: row.state) ?? .interrupted
        return request
    }
    private func metadata(_ row: DialogRecord) -> StoredConversation {
        var result = StoredConversation(id: row.id, createdAt: row.createdAt)
        result.archivedAt = row.archivedAt
        result.summaryTitle = row.title
        result.titleError = row.titleError
        result.turnCount = row.count
        result.latestUser = row.latestUser
        return result
    }
    public func loadCurrent() async throws -> ConversationCheckpoint? {
        let row = try await repository.current(agent: agent)
        let conversation = try await window(row.id)
        return ConversationCheckpoint(conversation: conversation, recovery: row.recovery, revision: row.revision)
    }
    public func isCurrent(_ id: String) async throws -> Bool {
        try await repository.current(agent: agent, includingRecovery: false).id == id
    }
    public func beginMessage(dialog id: String, identity: MessageIdentity) async throws -> String {
        try await writeGate.withAccess { [self] in
            _ = try await ownedDialog(id)
            return try await repository.beginMessage(dialog: id, identity: identity)
        }
    }
    @discardableResult public func saveCurrent(_ snapshot: ConversationCheckpoint) async throws -> [MessageReference] {
        try await writeGate.withAccess(honorCancellation: false) { [self] in try await saveCurrentLocked(snapshot) }
    }
    private func saveCurrentLocked(_ snapshot: ConversationCheckpoint) async throws -> [MessageReference] {
        _ = try await ownedDialog(snapshot.conversation.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var messages: [MessageRecord] = []
        var changes: [String: Data] = [:]
        for turn in snapshot.conversation.turns where snapshot.changedInputs?.contains(turn.id) ?? true {
            var input = turn
            // The SQL primary key is published after INSERT and is not duplicated in evidence.
            input.messageID = nil
            input.response = ""
            input.modelRequests = nil
            input.toolCalls = nil
            let inputData = try encoder.encode(input)
            let inputKey = turn.id + ":user"
            let inputFingerprint = ContentFingerprint.digest(inputData)
            if saved[inputKey] != inputFingerprint || turn.messageID == nil {
                messages.append(
                    MessageRecord(
                        clientID: turn.id, inputID: turn.id, role: "user", kind: "input",
                        order: turn.historyOrder, date: turn.date, body: turn.user, state: "completed",
                        detail: inputData, id: turn.messageID))
                changes[inputKey] = inputFingerprint
            }
            for request in turn.modelRequests ?? [] {
                // Observations are complete before the next invocation; assistant partials are not admitted here.
                if request.id != turn.modelRequests?.first?.id {
                    let key = request.id + ":observation"
                    let data = try encoder.encode(request.input)
                    let fingerprint = ContentFingerprint.digest(data)
                    if saved[key] != fingerprint {
                        messages.append(
                            MessageRecord(
                                clientID: request.id, inputID: turn.id, role: "user", kind: "observation",
                                order: request.historyOrder, date: request.date, body: request.input,
                                state: "completed",
                                taskID: request.historyTaskID, detail: data, id: request.inputMessageID))
                        changes[key] = fingerprint
                    }
                }
                guard request.state != .generating else { continue }
                var detail = request
                detail.response = ""
                detail.input = ""
                let detailData = try encoder.encode(detail)
                // Body is compared separately so a changed response never disappears behind the evidence hash.
                var fingerprintBytes = detailData
                fingerprintBytes.append(Data(request.response.utf8))
                let fingerprint = ContentFingerprint.digest(fingerprintBytes)
                let key = request.id + ":assistant"
                if saved[key] != fingerprint {
                    messages.append(
                        MessageRecord(
                            clientID: request.id, inputID: turn.id, role: "assistant", kind: "response",
                            order: request.historyOrder, date: request.date, body: request.response,
                            state: request.state.rawValue,
                            taskID: request.historyTaskID, detail: detailData, id: request.messageID))
                    changes[key] = fingerprint
                }
            }
        }
        var summaries: [TaskCompressionRecord] = []
        var summaryChanges: [String: Data] = [:]
        for compression in snapshot.conversation.taskCompressions {
            var sources = Dictionary(
                uniqueKeysWithValues: try await repository.taskSources(compression.taskID).map { ($0.requestID, $0) })
            for turn in snapshot.conversation.turns {
                for request in turn.modelRequests ?? []
                where request.historyTaskID == compression.taskID && request.state != .generating {
                    sources[request.id] = TaskSourceRecord(
                        inputID: turn.id, requestID: request.id, position: request.historyOrder)
                }
            }
            let complete = ConversationTaskCompression(
                taskID: compression.taskID, goal: compression.goal, status: compression.status,
                reportedSummary: compression.reportedSummary, failure: compression.failure,
                completedAt: compression.completedAt,
                sources: sources.values.sorted { $0.position < $1.position }.map {
                    .init(inputID: $0.inputID, requestID: $0.requestID)
                })
            let data = try encoder.encode(complete)
            let summaryFingerprint = ContentFingerprint.digest(data)
            if savedSummaries[compression.taskID] != summaryFingerprint {
                summaries.append(
                    TaskCompressionRecord(
                        id: complete.taskID, goal: complete.goal, status: complete.status.rawValue,
                        summary: complete.reportedSummary, failure: complete.failure, finishedAt: complete.completedAt,
                        sources: complete.sources.map(\.requestID), detail: data))
                summaryChanges[compression.taskID] = summaryFingerprint
            }
        }
        let references = try await repository.save(
            dialog: snapshot.conversation.id, revision: snapshot.revision, recovery: snapshot.recovery,
            messages: messages, summaries: summaries)
        saved.merge(changes) { _, new in new }
        savedSummaries.merge(summaryChanges) { _, new in new }
        var retained: Set<String> = []
        for turn in snapshot.conversation.turns {
            retained.insert(turn.id + ":user")
            for request in turn.modelRequests ?? [] {
                retained.insert(request.id + ":observation")
                retained.insert(request.id + ":assistant")
            }
        }
        saved = saved.filter { retained.contains($0.key) }
        let summariesInWindow = Set(snapshot.conversation.taskCompressions.map(\.taskID))
        savedSummaries = savedSummaries.filter { summariesInWindow.contains($0.key) }
        checkpointCount += 1
        return references
    }
    public func currentMetadata() async throws -> StoredConversation {
        metadata(try await repository.current(agent: agent, includingRecovery: false))
    }
    public func list(before: Int64? = nil, limit: Int = HistoryPaging.pageSize) async throws -> [StoredConversation] {
        try await repository.listDialogs(agent: agent, before: before, limit: limit).map(metadata)
    }
    public func read(_ id: String) async throws -> StoredConversation {
        var result = metadata(try await ownedDialog(id))
        var records: [MessageRecord] = []
        var cursor: Int64?
        while true {
            let page = try await repository.messages(dialog: id, after: cursor)
            records += page
            guard page.count == 50, let last = page.last?.id,
                let key = BusinessRecordID(rawValue: last)
            else { break }
            cursor = key.number
        }
        for item in records where item.kind == "input" {
            var turn = try Self.decodeInput(item)
            turn.messageID = item.id
            turn.user = item.body
            turn.modelRequests = []
            let responses = records.filter { $0.inputID == item.clientID && $0.role == "assistant" }
                .sorted { $0.order < $1.order }
            for response in responses {
                var request = try Self.decodeResponse(response)
                request.messageID = response.id
                request.response = response.body
                request.input =
                    records.first { $0.clientID == response.clientID && $0.kind == "observation" }?.body ?? item.body
                turn.modelRequests?.append(request)
            }
            turn.response = (turn.modelRequests ?? []).map(\.response).joined()
            turn.toolCalls = (turn.modelRequests ?? []).flatMap(\.toolCalls)
            result.turns.append(turn)
        }
        result.taskCompressions = try await repository.compressionData(dialog: id).map {
            try JSONDecoder().decode(ConversationTaskCompression.self, from: $0)
        }
        return result
    }
    public func rotate(_ snapshot: ConversationCheckpoint) async throws -> StoredConversation {
        try await writeGate.withAccess { [self] in try await rotateLocked(snapshot) }
    }
    private func rotateLocked(_ snapshot: ConversationCheckpoint) async throws -> StoredConversation {
        _ = try await saveCurrentLocked(snapshot)
        let next = try await repository.rotate(snapshot.conversation.id, agent: agent)
        saved.removeAll()
        savedSummaries.removeAll()
        return metadata(next)
    }
    public func update(_ conversation: StoredConversation) async throws {
        try await saveCurrent(.init(conversation: conversation))
    }
    public func setTitle(_ title: String?, error: String?, for id: String) async throws {
        try await writeGate.withAccess { [self] in try await setTitleLocked(title, error: error, for: id) }
    }
    private func setTitleLocked(_ title: String?, error: String?, for id: String) async throws {
        _ = try await ownedDialog(id)
        try await repository.setTitle(title, error: error, dialog: id)
    }
    public func delete(_ id: String) async throws {
        try await writeGate.withAccess { [self] in try await deleteLocked(id) }
    }
    private func deleteLocked(_ id: String) async throws {
        _ = try await ownedDialog(id)
        try await repository.deleteDialog(id)
    }
}

extension ConversationRecordStore {
    public func page(
        _ id: String, after: UInt64 = 0, taskID: String? = nil, limit: Int = HistoryPaging.pageSize, offset: Int = 0
    )
        async throws
        -> StoredConversation
    {
        var result = metadata(try await ownedDialog(id))
        result.isWindow = true
        let previews = try await repository.previews(
            dialog: id, after: after, taskID: taskID, limit: limit, offset: offset)
        for preview in previews {
            var request = ConversationModelRequest(
                id: preview.clientID, input: preview.input, requestJSON: "[]", historyTaskID: preview.taskID,
                date: preview.date)
            request.messageID = preview.id
            request.historyOrder = preview.position
            request.response = preview.response
            request.state = ConversationRecord.State(rawValue: preview.state) ?? .interrupted
            request.isObservation = preview.isObservation
            var turn = ConversationRecord(
                id: preview.inputID, date: preview.date, user: preview.input, request: [], model: "",
                maximumOutputTokens: nil, temperature: 0.7)
            turn.modelRequests = [request]
            turn.state = request.state
            result.turns.append(turn)
        }
        if previews.count == limit { result.nextPosition = previews.last?.position }
        result.taskCompressions = try await repository.compressionData(
            dialog: id, taskIDs: Array(Set(previews.compactMap(\.taskID)))
        ).map { try JSONDecoder().decode(ConversationTaskCompression.self, from: $0) }
        return result
    }
    public func message(_ id: String) async throws -> StoredConversation {
        _ = try await ownedDialog(try await repository.dialogForMessage(id))
        let rows = try await repository.messageEvidence(id)
        guard let user = rows.first(where: { $0.kind == "input" }),
            let selected = rows.first(where: { $0.id == id })
        else { throw ConversationHistoryError.missingTurn }
        if selected.role == "user" {
            var turn = try Self.decodeInput(user)
            var request = ConversationModelRequest(
                id: selected.clientID, input: selected.body,
                requestJSON: selected.kind == "input"
                    ? String(decoding: try JSONEncoder().encode(turn.request), as: UTF8.self) : "[]",
                historyTaskID: selected.taskID, date: selected.date)
            request.messageID = id
            request.historyOrder = selected.order
            request.state = ConversationRecord.State(rawValue: selected.state) ?? .interrupted
            request.isObservation = selected.kind == "observation"
            turn.modelRequests = [request]
            var result = StoredConversation(id: "detail")
            result.turns = [turn]
            return result
        }
        let response = selected
        var turn = try Self.decodeInput(user)
        var request = try Self.decodeResponse(response)
        turn.messageID = user.id
        turn.user = user.body
        request.messageID = response.id
        request.response = response.body
        request.isObservation = rows.contains { $0.kind == "observation" }
        request.input = rows.first(where: { $0.kind == "observation" })?.body ?? user.body
        turn.modelRequests = [request]
        var result = StoredConversation(id: "detail")
        result.turns = [turn]
        return result
    }
}

extension ConversationRecordStore {
    /// Ten projected blocks, plus admitted unanswered messages. The durable dialog is never truncated.
    public func window(_ id: String, preserving: [ConversationRecord] = []) async throws -> StoredConversation {
        var result = metadata(try await ownedDialog(id))
        result.isWindow = true
        var turns: [String: ConversationRecord] = [:]
        for preview in try await repository.latestPreviews(dialog: id) {
            let rows = try await repository.messageEvidence(preview.id)
            guard let input = rows.first(where: { $0.kind == "input" }),
                let response = rows.first(where: { $0.id == preview.id })
            else { continue }
            var turn = try turns[input.clientID] ?? Self.decodeInput(input)
            if turns[input.clientID] == nil { turn.modelRequests = [] }
            turn.messageID = input.id
            turn.user = input.body
            var request = try Self.decodeResponse(response)
            request.messageID = response.id
            request.response = response.body
            request.input = rows.first(where: { $0.kind == "observation" })?.body ?? input.body
            request.isObservation = rows.contains { $0.kind == "observation" }
            turn.modelRequests?.append(request)
            turns[input.clientID] = turn
        }
        for item in try await repository.unfinishedUserMessages(dialog: id)
        where item.kind == "input" && !item.detail.isEmpty && turns[item.inputID] == nil {
            var turn = try Self.decodeInput(item)
            turn.messageID = item.id
            turn.user = item.body
            turns[item.inputID] = turn
        }
        for item in preserving { turns[item.id] = item }
        result.turns = turns.values.map { original in
            var turn = original
            turn.modelRequests?.sort { $0.historyOrder < $1.historyOrder }
            turn.response = (turn.modelRequests ?? []).map(\.response).joined()
            turn.toolCalls = (turn.modelRequests ?? []).flatMap(\.toolCalls)
            return turn
        }.sorted { $0.historyOrder < $1.historyOrder }
        let taskIDs = Set(result.turns.flatMap { ($0.modelRequests ?? []).compactMap(\.historyTaskID) })
        result.taskCompressions = try await repository.compressionData(dialog: id, taskIDs: Array(taskIDs)).map {
            try JSONDecoder().decode(ConversationTaskCompression.self, from: $0)
        }
        return result
    }
}

extension ConversationRecordStore {
    public func dialogMetadata(_ id: String) async throws -> StoredConversation { metadata(try await ownedDialog(id)) }
    public func titleExcerpt(_ id: String, positions: [Int]) async throws -> StoredConversation {
        var result = metadata(try await ownedDialog(id))
        result.turns = try await repository.titleRows(dialog: id, positions: positions).map { row in
            var turn = ConversationRecord(
                id: row.inputID, date: row.date, user: row.input, request: [], model: "", maximumOutputTokens: nil,
                temperature: 0)
            turn.response = row.response
            turn.state = .completed
            return turn
        }
        return result
    }
}

extension ConversationRecordStore {
    public func input(_ id: String) async throws -> StoredConversation? {
        guard let dialog = try await repository.dialogForInput(id) else { return nil }
        var result = metadata(try await ownedDialog(dialog))
        result.isWindow = true
        let rows = try await repository.inputRows(id, dialog: dialog)
        guard let user = rows.first(where: { $0.kind == "input" }) else { return nil }
        var turn = try Self.decodeInput(user)
        turn.messageID = user.id
        turn.modelRequests = []
        for response in rows where response.role == "assistant" {
            var request = try Self.decodeResponse(response)
            request.messageID = response.id
            request.response = response.body
            request.input =
                rows.first { $0.clientID == response.clientID && $0.kind == "observation" }?.body ?? user.body
            turn.modelRequests?.append(request)
        }
        turn.response = (turn.modelRequests ?? []).map(\.response).joined()
        turn.toolCalls = (turn.modelRequests ?? []).flatMap(\.toolCalls)
        result.turns = [turn]
        return result
    }
}
