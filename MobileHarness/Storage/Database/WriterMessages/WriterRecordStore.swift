import Foundation
import StorageCore

public struct WriterCheckpoint: Sendable {
    public let version = 1
    public var conversation: WriterHistorySnapshot
    public let revision: UInt64
    public var changedInputs: Set<String>? = nil
    public init(conversation: WriterHistorySnapshot, revision: UInt64 = 0) {
        self.conversation = conversation
        self.revision = revision
    }
}

/// SQL adapter for complete messages; no document/index/rotation persistence remains.
public actor WriterRecordStore {
    internal nonisolated let repository: any WriterMessageRepository
    private let logs: any ModelRequestLogRepository
    public private(set) var checkpointCount = 0
    private let writeGate = StorageOperationGate()
    private var saved: [String: Data] = [:]
    var cachedFingerprintCount: Int { saved.count }
    public init(repository: any WriterMessageRepository, logs: any ModelRequestLogRepository) throws {
        guard repository.storageScope == logs.storageScope else { throw RecordStorageError.invalidRecord }
        self.repository = repository
        self.logs = logs
    }
    public func containsInput(_ id: String) async throws -> Bool {
        guard let dialog = try await repository.taskForInput(id) else { return false }
        _ = try await repository.ownerMetadata(dialog)
        return true
    }
    private func historyOwner(_ id: String) async throws -> WriterHistoryMetadata {
        let row = try await repository.ownerMetadata(id)
        return row
    }
    private static func state(_ raw: String) throws -> WriterRecord.State {
        guard let value = WriterRecord.State(rawValue: raw) else { throw RecordStorageError.invalidRecord }
        return value
    }
    private static func decodeInput(_ row: WriterMessageRecord) throws -> WriterRecord {
        if !row.detail.isEmpty {
            return try JSONDecoder().decode(WriterRecord.self, from: row.detail)
        }
        var turn = WriterRecord(
            id: row.clientID, date: row.date, user: row.body, request: [], model: "",
            maximumOutputTokens: nil, temperature: 0)
        turn.historyOrder = row.order
        turn.state = try Self.state(row.state)
        return turn
    }
    private static func decodeResponse(_ row: WriterMessageRecord) throws -> WriterModelRequest {
        var request: WriterModelRequest
        if row.detail.isEmpty {
            request = WriterModelRequest(
                id: row.clientID, input: "", requestJSON: "[]", date: row.date)
            request.historyOrder = row.order
        } else {
            request = try JSONDecoder().decode(WriterModelRequest.self, from: row.detail)
        }
        request.state = try Self.state(row.state)
        return request
    }
    private func metadata(_ row: WriterHistoryMetadata) -> WriterHistorySnapshot {
        var result = WriterHistorySnapshot(id: row.id, createdAt: row.createdAt)
        result.archivedAt = row.archivedAt
        result.summaryTitle = row.title
        result.titleError = row.titleError
        result.turnCount = row.count
        result.latestUser = row.latestUser
        return result
    }
    public func loadCurrent() async throws -> WriterCheckpoint? {
        let row = try await repository.current()
        let conversation = try await window(row.id)
        return WriterCheckpoint(conversation: conversation, revision: row.revision)
    }
    public func isCurrent(_ id: String) async throws -> Bool {
        try await repository.current().id == id
    }
    public func beginMessage(ownerID id: String, identity: WriterMessageIdentity) async throws -> String {
        try await writeGate.withAccess { [self] in
            _ = try await historyOwner(id)
            return try await repository.beginMessage(ownerID: id, identity: identity)
        }
    }
    @discardableResult public func saveCurrent(_ snapshot: WriterCheckpoint) async throws -> [WriterMessageReference] {
        try await writeGate.withAccess(honorCancellation: false) { [self] in try await saveCurrentLocked(snapshot) }
    }
    private func saveCurrentLocked(_ snapshot: WriterCheckpoint) async throws -> [WriterMessageReference] {
        _ = try await historyOwner(snapshot.conversation.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var messages: [WriterMessageRecord] = []
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
                    WriterMessageRecord(
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
                            WriterMessageRecord(
                                clientID: request.id, inputID: turn.id, role: "user", kind: "observation",
                                order: request.historyOrder, date: request.date, body: request.input,
                                state: "completed",
                                detail: data, id: request.inputMessageID))
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
                        WriterMessageRecord(
                            clientID: request.id, inputID: turn.id, role: "assistant", kind: "response",
                            order: request.historyOrder, date: request.date, body: request.response,
                            state: request.state.rawValue,
                            detail: detailData, id: request.messageID))
                    changes[key] = fingerprint
                }
            }
        }
        let references = try await repository.save(
            ownerID: snapshot.conversation.id, revision: snapshot.revision,
            messages: messages)
        saved.merge(changes) { _, new in new }
        var retained: Set<String> = []
        for turn in snapshot.conversation.turns {
            retained.insert(turn.id + ":user")
            for request in turn.modelRequests ?? [] {
                retained.insert(request.id + ":observation")
                retained.insert(request.id + ":assistant")
            }
        }
        saved = saved.filter { retained.contains($0.key) }
        checkpointCount += 1
        return references
    }
    public func currentMetadata() async throws -> WriterHistorySnapshot {
        metadata(try await repository.current())
    }
    public func read(_ id: String) async throws -> WriterHistorySnapshot {
        var result = metadata(try await historyOwner(id))
        var records: [WriterMessageRecord] = []
        var cursor: Int64?
        while true {
            let page = try await repository.messagePage(ownerID: id, after: cursor, limit: 50)
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
                    let log = try await logs.requestPayload(id, agent: "writer")
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
        return result
    }
    public func update(_ conversation: WriterHistorySnapshot) async throws {
        try await saveCurrent(.init(conversation: conversation))
    }
}

extension WriterRecordStore {
    public func requestCount(_ id: String) async throws -> Int {
        _ = try await historyOwner(id)
        return try await repository.timelineCount(ownerID: id)
    }
    public func requestPreviews(_ id: String, after: UInt64, limit: Int = 20) async throws -> [WriterMessagePreview] {
        _ = try await historyOwner(id)
        return try await repository.previews(ownerID: id, after: after, limit: limit, offset: 0)
    }
    public func requestPreviews(_ id: String, before: UInt64?, limit: Int) async throws -> [WriterMessagePreview] {
        _ = try await historyOwner(id)
        return try await repository.previews(ownerID: id, before: before, limit: limit)
    }
    public func page(
        _ id: String, after: UInt64 = 0, limit: Int = HistoryPaging.pageSize, offset: Int = 0
    )
        async throws
        -> WriterHistorySnapshot
    {
        var result = metadata(try await historyOwner(id))
        result.isWindow = true
        let previews = try await repository.previews(
            ownerID: id, after: after, limit: limit, offset: offset)
        for preview in previews {
            var request = WriterModelRequest(
                id: preview.clientID, input: preview.input, requestJSON: "[]", date: preview.date)
            request.messageID = preview.id
            request.historyOrder = preview.position
            request.response = preview.response
            request.state = try Self.state(preview.state)
            request.isObservation = preview.isObservation
            var turn = WriterRecord(
                id: preview.inputID, date: preview.date, user: preview.input, request: [], model: "",
                maximumOutputTokens: nil, temperature: 0.7)
            turn.modelRequests = [request]
            turn.state = request.state
            result.turns.append(turn)
        }
        if previews.count == limit { result.nextPosition = previews.last?.position }
        return result
    }
    public func message(_ id: String) async throws -> WriterHistorySnapshot {
        _ = try await historyOwner(try await repository.taskForMessage(id))
        let rows = try await repository.messageEvidence(id)
        guard let user = rows.first(where: { $0.kind == "input" }),
            let selected = rows.first(where: { $0.id == id })
        else { throw WriterHistoryError.missingTurn }
        if selected.role == "user" {
            var turn = try Self.decodeInput(user)
            var request = WriterModelRequest(
                id: selected.clientID, input: selected.body,
                requestJSON: selected.kind == "input"
                    ? String(decoding: try JSONEncoder().encode(turn.request), as: UTF8.self) : "[]",
                date: selected.date)
            request.messageID = id
            request.historyOrder = selected.order
            request.state = try Self.state(selected.state)
            request.isObservation = selected.kind == "observation"
            turn.modelRequests = [request]
            var result = WriterHistorySnapshot(id: "detail")
            result.turns = [turn]
            return result
        }
        let response = selected
        var turn = try Self.decodeInput(user)
        var request = try Self.decodeResponse(response)
        if let id = response.id {
            let log = try await logs.requestPayload(id, agent: "writer")
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
        var result = WriterHistorySnapshot(id: "detail")
        result.turns = [turn]
        return result
    }

    public func detailContext(_ id: String, toolCallIDs: [String]) async throws -> WriterMessageDetailContext {
        try await repository.detailContext(id, toolCallIDs: toolCallIDs)
    }
}

extension WriterRecordStore {
    /// Ten projected blocks, plus admitted unanswered messages. The durable dialog is never truncated.
    public func window(_ id: String, preserving: [WriterRecord] = []) async throws -> WriterHistorySnapshot {
        var result = metadata(try await historyOwner(id))
        result.isWindow = true
        var turns: [String: WriterRecord] = [:]
        for preview in try await repository.latestPreviews(ownerID: id) where !preview.isInput {
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
        for item in try await repository.unfinishedUserMessages(ownerID: id)
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
        return result
    }
}

extension WriterRecordStore {
    public func ownerMetadata(_ id: String) async throws -> WriterHistorySnapshot {
        metadata(try await historyOwner(id))
    }
}

extension WriterRecordStore {
    public func input(_ id: String) async throws -> WriterHistorySnapshot? {
        guard let dialog = try await repository.taskForInput(id) else { return nil }
        var result = metadata(try await historyOwner(dialog))
        result.isWindow = true
        let rows = try await repository.inputRows(id, ownerID: dialog)
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

extension WriterRecordStore {
    public func writeRequestPayload(
        _ requestID: String, json: String, response: String, initial: Bool, update: ModelRequestLogUpdate? = nil
    ) async throws {
        try await writeGate.withAccess { [self] in
            try await logs.writeRequestPayload(
                requestID, agent: "writer", json: json, response: response, initial: initial, update: update)
        }
    }
    public func clearRequestLogs(requestID: String?) async throws {
        try await writeGate.withAccess { [self] in
            if let requestID { _ = try await repository.taskForMessage(requestID) }
            try await logs.clearRequestLogs(agent: "writer", requestID: requestID)
        }
    }
}
