import Foundation
import StorageCore
import StorageTasks

public struct AssistantCheckpoint: Sendable {
    public let version = 1
    public var conversation: AssistantConversation
    public let revision: UInt64
    public var changedInputs: Set<String>? = nil
    public init(conversation: AssistantConversation, revision: UInt64 = 0) {
        self.conversation = conversation
        self.revision = revision
    }
}

/// SQL adapter for complete messages; no document/index/rotation persistence remains.
public actor AssistantRecordStore {
    internal nonisolated let repository: any AssistantMessageRepository
    public nonisolated let tasks: any AssistantTaskRepository & AssistantTaskSummaryRepository
    internal nonisolated let conversations: any AssistantConversationRepository
    internal nonisolated let logs: any ModelRequestLogRepository
    public private(set) var checkpointCount = 0
    private let writeGate = StorageOperationGate()
    private var saved: [String: Data] = [:]
    private var savedSummaries: [String: Data] = [:]
    var cachedFingerprintCount: Int { saved.count + savedSummaries.count }
    public init(
        repository: any AssistantMessageRepository, tasks: any AssistantTaskRepository & AssistantTaskSummaryRepository,
        conversations: any AssistantConversationRepository, logs: any ModelRequestLogRepository
    ) throws {
        guard repository.storageScope == tasks.storageScope, repository.storageScope == conversations.storageScope,
            repository.storageScope == logs.storageScope
        else { throw RecordStorageError.invalidRecord }
        self.repository = repository
        self.tasks = tasks
        self.conversations = conversations
        self.logs = logs
    }
    public func containsInput(_ id: String) async throws -> Bool {
        guard let dialog = try await repository.dialogForInput(id) else { return false }
        _ = try await conversations.dialog(dialog)
        return true
    }
    private func ownedDialog(_ id: String) async throws -> AssistantConversationRecord {
        let row = try await conversations.dialog(id)
        return row
    }
    private static func state(_ raw: String) throws -> AssistantRecord.State {
        guard let value = AssistantRecord.State(rawValue: raw) else { throw RecordStorageError.invalidRecord }
        return value
    }
    private static func decodeInput(_ row: AssistantMessageRecord) throws -> AssistantRecord {
        if !row.detail.isEmpty {
            return try JSONDecoder().decode(AssistantRecord.self, from: row.detail)
        }
        var turn = AssistantRecord(
            id: row.clientID, date: row.date, user: row.body, request: [], model: "",
            maximumOutputTokens: nil, temperature: 0)
        turn.historyOrder = row.order
        turn.state = try Self.state(row.state)
        return turn
    }
    private static func decodeResponse(_ row: AssistantMessageRecord) throws -> AssistantModelRequest {
        var request: AssistantModelRequest
        if row.detail.isEmpty {
            request = AssistantModelRequest(
                id: row.clientID, input: "", requestJSON: "[]", historyTaskID: row.taskID, date: row.date)
            request.historyOrder = row.order
        } else {
            request = try JSONDecoder().decode(AssistantModelRequest.self, from: row.detail)
        }
        request.state = try Self.state(row.state)
        return request
    }
    private func metadata(_ row: AssistantConversationRecord) -> AssistantConversation {
        var result = AssistantConversation(id: row.id, createdAt: row.createdAt)
        result.archivedAt = row.archivedAt
        result.summaryTitle = row.title
        result.titleError = row.titleError
        result.turnCount = row.count
        result.latestUser = row.latestUser
        return result
    }
    public func loadCurrent() async throws -> AssistantCheckpoint? {
        let row = try await conversations.current()
        let conversation = try await window(row.id)
        return AssistantCheckpoint(conversation: conversation, revision: row.revision)
    }
    public func isCurrent(_ id: String) async throws -> Bool {
        try await conversations.current().id == id
    }
    public func beginMessage(dialog id: String, identity: AssistantMessageIdentity) async throws -> String {
        try await writeGate.withAccess { [self] in
            _ = try await ownedDialog(id)
            return try await repository.beginMessage(dialog: id, identity: identity)
        }
    }
    @discardableResult public func saveCurrent(_ snapshot: AssistantCheckpoint) async throws
        -> [AssistantMessageReference]
    {
        try await writeGate.withAccess(honorCancellation: false) { [self] in try await saveCurrentLocked(snapshot) }
    }
    private func saveCurrentLocked(_ snapshot: AssistantCheckpoint) async throws -> [AssistantMessageReference] {
        _ = try await ownedDialog(snapshot.conversation.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var messages: [AssistantMessageRecord] = []
        var changes: [String: Data] = [:]
        for turn in snapshot.conversation.turns where snapshot.changedInputs?.contains(turn.id) ?? true {
            var input = turn
            // The SQL primary key is published after INSERT and is not duplicated in evidence.
            input.messageID = nil
            input.request = []
            input.response = ""
            input.modelRequests = nil
            input.toolCalls = nil
            let inputData = try encoder.encode(input)
            let inputKey = turn.id + ":user"
            let inputFingerprint = ContentFingerprint.digest(inputData)
            if saved[inputKey] != inputFingerprint || turn.messageID == nil {
                messages.append(
                    AssistantMessageRecord(
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
                            AssistantMessageRecord(
                                clientID: request.id, inputID: turn.id, role: "user", kind: "observation",
                                order: request.historyOrder, date: request.date, body: request.input,
                                state: "completed",
                                taskID: request.historyTaskID, detail: data, id: request.inputMessageID))
                        changes[key] = fingerprint
                    }
                }
                guard request.state != .generating || request.producerMetadata != nil else { continue }
                var detail = request
                detail.response = ""
                detail.input = ""
                guard var evidence = try JSONSerialization.jsonObject(with: encoder.encode(detail)) as? [String: Any]
                else { throw RecordStorageError.invalidRecord }
                evidence["model"] = turn.model
                evidence["temperature"] = turn.temperature
                evidence["maximumOutputTokens"] = turn.maximumOutputTokens
                let detailData = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                // Body is compared separately so a changed response never disappears behind the evidence hash.
                var fingerprintBytes = detailData
                fingerprintBytes.append(Data(request.response.utf8))
                let fingerprint = ContentFingerprint.digest(fingerprintBytes)
                let key = request.id + ":assistant"
                if saved[key] != fingerprint {
                    messages.append(
                        AssistantMessageRecord(
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
                uniqueKeysWithValues: try await tasks.taskSources(compression.taskID).map { ($0.requestID, $0) })
            for turn in snapshot.conversation.turns {
                for request in turn.modelRequests ?? []
                where request.historyTaskID == compression.taskID && request.state != .generating {
                    sources[request.id] = TaskSourceRecord(
                        inputID: turn.id, requestID: request.id, position: request.historyOrder)
                }
            }
            let complete = AssistantTaskCompression(
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
            dialog: snapshot.conversation.id, revision: snapshot.revision,
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
    public func currentMetadata() async throws -> AssistantConversation {
        metadata(try await conversations.current())
    }
    public func list(before: Int64? = nil, limit: Int = HistoryPaging.pageSize) async throws -> [AssistantConversation]
    {
        try await conversations.listDialogs(before: before, limit: limit).map(metadata)
    }
    public func read(_ id: String) async throws -> AssistantConversation {
        var result = metadata(try await ownedDialog(id))
        var records: [AssistantMessageRecord] = []
        var cursor: Int64?
        while true {
            let page = try await repository.messagePage(dialog: id, after: cursor, limit: 50)
            records += page.records
            guard let next = page.next else { break }
            cursor = next
        }
        var seenInputs: Set<String> = []
        for item in records where item.kind == "input" && seenInputs.insert(item.inputID).inserted {
            var turn = try Self.decodeInput(item)
            turn.messageID = item.id
            turn.user = item.body
            turn.modelRequests = []
            let responses = records.filter { $0.inputID == item.clientID && $0.role == "assistant" }
                .sorted { $0.order < $1.order }
            for response in responses {
                var request = try Self.decodeResponse(response)
                if let id = response.id {
                    let log = try await logs.requestPayload(id, agent: "assistant")
                    request.requestParametersJSON = log?.requestJSON
                    request.responseEventsJSON = log?.responseJSON
                    request.logsCleared = log == nil
                }
                request.messageID = response.id
                request.response = response.body
                request.input =
                    records.first { $0.clientID == response.clientID && $0.kind == "observation" }?.body ?? item.body
                if turn.request.isEmpty,
                    let original = try? JSONDecoder().decode(
                        [ModelMessage].self, from: Data(request.requestJSON.utf8))
                {
                    turn.request = original
                }
                turn.modelRequests?.append(request)
            }
            turn.response = (turn.modelRequests ?? []).map(\.response).joined()
            turn.toolCalls = (turn.modelRequests ?? []).flatMap(\.toolCalls)
            turn.tokenUsage = turn.modelRequests?.last?.tokenUsage
            turn.state = turn.modelRequests?.last?.state ?? turn.state
            result.turns.append(turn)
        }
        result.taskCompressions = try await tasks.compressionData(dialog: id).map {
            try JSONDecoder().decode(AssistantTaskCompression.self, from: $0)
        }
        return result
    }
    public func rotate(_ snapshot: AssistantCheckpoint) async throws -> AssistantConversation {
        try await writeGate.withAccess { [self] in try await rotateLocked(snapshot) }
    }
    private func rotateLocked(_ snapshot: AssistantCheckpoint) async throws -> AssistantConversation {
        _ = try await saveCurrentLocked(snapshot)
        let next = try await conversations.rotate(snapshot.conversation.id)
        saved.removeAll()
        savedSummaries.removeAll()
        return metadata(next)
    }
    public func update(_ conversation: AssistantConversation) async throws {
        try await saveCurrent(.init(conversation: conversation))
    }
    public func setTitle(_ title: String?, error: String?, for id: String) async throws {
        try await writeGate.withAccess { [self] in try await setTitleLocked(title, error: error, for: id) }
    }
    private func setTitleLocked(_ title: String?, error: String?, for id: String) async throws {
        _ = try await ownedDialog(id)
        try await conversations.setTitle(title, error: error, dialog: id)
    }
    public func delete(_ id: String) async throws {
        try await writeGate.withAccess { [self] in try await deleteLocked(id) }
    }
    private func deleteLocked(_ id: String) async throws {
        _ = try await ownedDialog(id)
        try await conversations.deleteDialog(id)
    }
}

extension AssistantRecordStore {
    public func requestCount(_ id: String) async throws -> Int {
        _ = try await ownedDialog(id)
        return try await repository.timelineCount(dialog: id)
    }
    public func requestPreviews(_ id: String, after: UInt64, limit: Int = 20) async throws -> [AssistantMessagePreview]
    {
        _ = try await ownedDialog(id)
        return try await repository.previews(dialog: id, after: after, taskID: nil, limit: limit, offset: 0)
    }
    public func page(
        _ id: String, after: UInt64 = 0, taskID: String? = nil, limit: Int = HistoryPaging.pageSize, offset: Int = 0
    )
        async throws
        -> AssistantConversation
    {
        var result = metadata(try await ownedDialog(id))
        result.isWindow = true
        let previews = try await repository.previews(
            dialog: id, after: after, taskID: taskID, limit: limit, offset: offset)
        for preview in previews {
            var request = AssistantModelRequest(
                id: preview.clientID, input: preview.input, requestJSON: "[]", historyTaskID: preview.taskID,
                date: preview.date)
            request.messageID = preview.id
            request.historyOrder = preview.position
            request.response = preview.response
            request.state = try Self.state(preview.state)
            request.isObservation = preview.isObservation
            var turn = AssistantRecord(
                id: preview.inputID, date: preview.date, user: preview.input, request: [], model: "",
                maximumOutputTokens: nil, temperature: 0.7)
            turn.modelRequests = [request]
            turn.state = request.state
            result.turns.append(turn)
        }
        if previews.count == limit { result.nextPosition = previews.last?.position }
        result.taskCompressions = try await tasks.compressionData(
            dialog: id, taskIDs: Array(Set(previews.compactMap(\.taskID)))
        ).map { try JSONDecoder().decode(AssistantTaskCompression.self, from: $0) }
        return result
    }
    public func message(_ id: String) async throws -> AssistantConversation {
        _ = try await ownedDialog(try await repository.dialogForMessage(id))
        let rows = try await repository.messageEvidence(id)
        guard let user = rows.first(where: { $0.kind == "input" }),
            let selected = rows.first(where: { $0.id == id })
        else { throw AssistantHistoryError.missingTurn }
        if selected.role == "user" {
            var turn = try Self.decodeInput(user)
            var request = AssistantModelRequest(
                id: selected.clientID, input: selected.body,
                requestJSON: selected.kind == "input"
                    ? String(decoding: try JSONEncoder().encode(turn.request), as: UTF8.self) : "[]",
                historyTaskID: selected.taskID, date: selected.date)
            request.messageID = id
            request.historyOrder = selected.order
            request.state = try Self.state(selected.state)
            request.isObservation = selected.kind == "observation"
            turn.modelRequests = [request]
            var result = AssistantConversation(id: "detail")
            result.turns = [turn]
            return result
        }
        let response = selected
        var turn = try Self.decodeInput(user)
        var request = try Self.decodeResponse(response)
        if let id = response.id {
            let log = try await logs.requestPayload(id, agent: "assistant")
            request.requestParametersJSON = log?.requestJSON
            request.responseEventsJSON = log?.responseJSON
            request.logsCleared = log == nil
        }
        turn.messageID = user.id
        turn.user = user.body
        request.messageID = response.id
        request.response = response.body
        request.isObservation = rows.contains { $0.kind == "observation" }
        request.input = rows.first(where: { $0.kind == "observation" })?.body ?? user.body
        turn.modelRequests = [request]
        var result = AssistantConversation(id: "detail")
        result.turns = [turn]
        return result
    }
}

extension AssistantRecordStore {
    /// Ten projected blocks, plus admitted unanswered messages. The durable dialog is never truncated.
    public func window(_ id: String, preserving: [AssistantRecord] = []) async throws -> AssistantConversation {
        var result = metadata(try await ownedDialog(id))
        result.isWindow = true
        var turns: [String: AssistantRecord] = [:]
        for preview in try await repository.latestPreviews(dialog: id) where !preview.isInput {
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
            if turn.request.isEmpty,
                let original = try? JSONDecoder().decode(
                    [ModelMessage].self, from: Data(request.requestJSON.utf8))
            {
                turn.request = original
            }
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
        let activeInputs = Dictionary(uniqueKeysWithValues: preserving.map { ($0.id, $0) })
        for item in preserving { turns[item.id] = item }
        result.turns = turns.values.map { original in
            // A completed model round can still await ReACT; preserve its owning input lifecycle.
            if let active = activeInputs[original.id] { return active }
            var turn = original
            turn.modelRequests?.sort { $0.historyOrder < $1.historyOrder }
            turn.response = (turn.modelRequests ?? []).map(\.response).joined()
            turn.toolCalls = (turn.modelRequests ?? []).flatMap(\.toolCalls)
            turn.tokenUsage = turn.modelRequests?.last?.tokenUsage
            turn.state = turn.modelRequests?.last?.state ?? turn.state
            return turn
        }.sorted { $0.historyOrder < $1.historyOrder }
        let taskIDs = Set(result.turns.flatMap { ($0.modelRequests ?? []).compactMap(\.historyTaskID) })
        result.taskCompressions = try await tasks.compressionData(dialog: id, taskIDs: Array(taskIDs)).map {
            try JSONDecoder().decode(AssistantTaskCompression.self, from: $0)
        }
        return result
    }
}

extension AssistantRecordStore {
    public func dialogMetadata(_ id: String) async throws -> AssistantConversation {
        metadata(try await ownedDialog(id))
    }
    public func titleExcerpt(_ id: String, positions: [Int]) async throws -> AssistantConversation {
        var result = metadata(try await ownedDialog(id))
        result.turns = try await repository.titleRows(dialog: id, positions: positions).map { row in
            var turn = AssistantRecord(
                id: row.inputID, date: row.date, user: row.input, request: [], model: "", maximumOutputTokens: nil,
                temperature: 0)
            turn.response = row.response
            turn.state = .completed
            return turn
        }
        return result
    }
}

extension AssistantRecordStore {
    public func input(_ id: String) async throws -> AssistantConversation? {
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
            if turn.request.isEmpty,
                let original = try? JSONDecoder().decode(
                    [ModelMessage].self, from: Data(request.requestJSON.utf8))
            {
                turn.request = original
            }
            turn.modelRequests?.append(request)
        }
        turn.response = (turn.modelRequests ?? []).map(\.response).joined()
        turn.toolCalls = (turn.modelRequests ?? []).flatMap(\.toolCalls)
        result.turns = [turn]
        return result
    }
}

extension AssistantRecordStore {
    public func writeRequestPayload(
        _ requestID: String, json: String, response: String, initial: Bool, update: ModelRequestLogUpdate? = nil
    ) async throws {
        try await writeGate.withAccess { [self] in
            try await logs.writeRequestPayload(
                requestID, agent: "assistant", json: json, response: response, initial: initial, update: update)
        }
    }
    public func clearRequestLogs(requestID: String?) async throws {
        try await writeGate.withAccess { [self] in
            if let requestID { _ = try await repository.dialogForMessage(requestID) }
            try await logs.clearRequestLogs(agent: "assistant", requestID: requestID)
        }
    }
}
