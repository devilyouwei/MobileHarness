import Foundation
import StorageCore

public actor WriterHistoryStore {
    public static let maximumBytes = 32 * 1024 * 1024
    public private(set) var lastCheckpointError: String?
    public nonisolated let storageScope: UUID
    private let records: WriterRecordStore
    private var value = WriterJournal()
    private var readToken = WriterReadToken(value: UUID().uuidString)
    private var savedID: String?
    private var savedRevision: UInt64?
    private var dirtyInputs: Set<String> = []
    private var needsCurrentSynchronization = false
    private var loaded = false
    private var writing = false
    private var writers: [CheckedContinuation<Void, Never>] = []

    private func acquireWrite() async throws {
        if !writing {
            writing = true
            return
        }
        guard writers.count < 16 else { throw WriterHistoryError.busy }
        await withCheckedContinuation { writers.append($0) }
    }

    private func releaseWrite() {
        if writers.isEmpty { writing = false } else { writers.removeFirst().resume() }
    }

    public init(records: WriterRecordStore) {
        self.records = records
        storageScope = records.repository.storageScope
    }
    private func load() async throws {
        guard !loaded else {
            if needsCurrentSynchronization { try await synchronizeCurrentLocked() }
            return
        }
        guard let saved = try await records.loadCurrent() else { throw RecordStorageError.missingRecord }
        value.current = saved.conversation
        value.revision = saved.revision
        savedID = saved.conversation.id
        savedRevision = saved.revision
        for index in value.current.turns.indices where value.current.turns[index].state == .generating {
            dirtyInputs.insert(value.current.turns[index].id)
            value.current.turns[index].state = .interrupted
            value.current.turns[index].error = "Interrupted; tools are never replayed"
            for request in value.current.turns[index].modelRequests?.indices ?? 0..<0
            where value.current.turns[index].modelRequests?[request].state == .generating {
                value.current.turns[index].modelRequests?[request].state = .interrupted
            }
        }
        if !dirtyInputs.isEmpty {
            guard value.revision < UInt64.max else { throw WriterHistoryError.capacityExceeded }
            value.revision += 1
        }
        loaded = true
    }

    /// Refreshes the delegation history only at operation boundaries, never per delta.
    private func synchronizeCurrentLocked() async throws {
        let current = try await records.currentMetadata()
        guard needsCurrentSynchronization || current.id != value.current.id else { return }
        if !needsCurrentSynchronization {
            guard dirtyInputs.isEmpty, !value.current.turns.contains(where: { $0.state == .generating }) else {
                throw WriterHistoryError.conflict
            }
        }
        needsCurrentSynchronization = true
        guard let saved = try await records.loadCurrent() else { throw RecordStorageError.missingRecord }
        var next = value
        next.current = saved.conversation
        next.revision = saved.revision
        try await commit(next)
        guard value.current.id == saved.conversation.id else { throw WriterHistoryError.conflict }
        dirtyInputs.removeAll()
        savedID = saved.conversation.id
        savedRevision = value.revision
        needsCurrentSynchronization = false
    }

    private func commit(_ candidate: WriterJournal) async throws {
        guard value.revision < UInt64.max else { throw WriterHistoryError.capacityExceeded }
        var next = candidate
        next.revision = max(value.revision, candidate.revision) + 1
        value = next
        readToken = WriterReadToken(value: UUID().uuidString)
    }

    private func checkpointLocked() async throws {
        do {
            try value.validate()
            var snapshot = WriterCheckpoint(conversation: value.current, revision: value.revision)
            snapshot.changedInputs = dirtyInputs
            guard snapshot.conversation.id == value.current.id else { throw WriterHistoryError.conflict }
            if snapshot.conversation.id == savedID && snapshot.revision == savedRevision {
                guard try await records.isCurrent(snapshot.conversation.id) else {
                    throw WriterHistoryError.conflict
                }
                return
            }
            let references = try await records.saveCurrent(snapshot)
            var next = value
            var attachedIdentity = false
            for reference in references where reference.role == "user" {
                if let index = next.current.turns.firstIndex(where: { $0.id == reference.clientID }),
                    next.current.turns[index].messageID == nil
                {
                    next.current.turns[index].messageID = reference.id
                    next.current.turns[index].historyOrder = UInt64(
                        try BusinessRecordID.number(reference.id, kind: .message))
                    attachedIdentity = true
                }
            }
            for reference in references where reference.role == "assistant" {
                for input in next.current.turns.indices {
                    guard
                        let request = next.current.turns[input].modelRequests?.firstIndex(where: {
                            $0.id == reference.clientID
                        })
                    else { continue }
                    next.current.turns[input].modelRequests?[request].messageID = reference.id
                    let inputMessageID = next.current.turns[input].messageID
                    next.current.turns[input].modelRequests?[request].inputMessageID = inputMessageID
                    next.current.turns[input].modelRequests?[request].historyOrder = UInt64(
                        try BusinessRecordID.number(reference.id, kind: .request))
                    attachedIdentity = true
                }
            }
            if attachedIdentity { try await commit(next) }
            dirtyInputs.subtract(snapshot.changedInputs ?? [])
            savedID = snapshot.conversation.id
            savedRevision = value.revision
            lastCheckpointError = nil
        } catch {
            lastCheckpointError = String(describing: error)
            throw error
        }
    }
    public func checkpoint(inputID: String? = nil) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if let inputID { dirtyInputs.insert(inputID) }
        try await checkpointLocked()
    }

    /// Serialize a workspace binding with checkpoints; existing message identities and scope never change.
    public func bindingWorkspace(_ operation: @Sendable () async throws -> Void) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await checkpointLocked()
        try await operation()
    }
    public func ownerHistory(_ id: String) async throws -> WriterHistorySnapshot {
        try await records.read(id)
    }

    public func page(_ id: String, after: UInt64 = 0) async throws -> WriterHistorySnapshot {
        try await acquireWrite()
        defer { releaseWrite() }
        return try await records.page(id, after: after)
    }

    public func message(_ id: String) async throws -> WriterHistorySnapshot {
        return try await records.message(id)
    }
    public func detailContext(_ id: String, toolCallIDs: [String]) async throws -> WriterMessageDetailContext {
        try await records.detailContext(id, toolCallIDs: toolCallIDs)
    }
    public func requestPreviews(_ id: String, after: UInt64, limit: Int = 20) async throws -> [WriterMessagePreview] {
        return try await records.requestPreviews(id, after: after, limit: limit)
    }
    public func requestPreviews(_ id: String, before: UInt64?, limit: Int) async throws -> [WriterMessagePreview] {
        try await records.requestPreviews(id, before: before, limit: limit)
    }
    public func requestCount(_ id: String) async throws -> Int { try await records.requestCount(id) }

    public func ownerMetadata(_ id: String) async throws -> WriterHistorySnapshot {
        try await records.ownerMetadata(id)
    }

    /// Identity-only duplicate lookup across this Agent's dialogs; never imports old dialog context.
    public func containsInput(_ id: String) async throws -> Bool { try await records.containsInput(id) }

    /// Reads records and a fence atomically, without selecting model context.
    public func readCurrent() async throws -> WriterReadSnapshot {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        return WriterReadSnapshot(current: value.current, token: readToken)
    }

    /// Admits user text before a model request exists, under one current-conversation write fence.
    public func admitUserInput(id: String, user: String, model: String) async throws -> WriterRecord {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        guard !value.current.turns.contains(where: { $0.id == id }) else {
            throw WriterHistoryError.invalidRecord
        }
        return try await beginLocked(
            id: id, user: user, request: [], model: model,
            maximumOutputTokens: nil, temperature: 0.7, awaitingModel: true)
    }

    /// Persists the caller's exact request, rejecting intervening mutations.
    public func begin(
        id: String, user: String, request: [ModelMessage], expecting token: WriterReadToken,
        model: String, maximumOutputTokens: Int? = nil, temperature: Double = 0.7, awaitingModel: Bool = false
    ) async throws -> WriterRecord {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        guard token == readToken else { throw WriterHistoryError.conflict }
        return try await beginLocked(
            id: id, user: user, request: request, model: model,
            maximumOutputTokens: maximumOutputTokens, temperature: temperature, awaitingModel: awaitingModel)
    }

    private func beginLocked(
        id: String, user: String, request: [ModelMessage], model: String,
        maximumOutputTokens: Int?, temperature: Double, awaitingModel: Bool
    ) async throws -> WriterRecord {
        guard user.utf8.count <= 4096, model.utf8.count <= 512,
            request.count <= 514,
            request.allSatisfy({ $0.content.utf8.count <= ($0.role == .system ? 65536 : 262144) }),
            temperature.isFinite, maximumOutputTokens.map({ $0 > 0 }) ?? true
        else { throw WriterHistoryError.invalidRecord }

        if let index = value.current.turns.firstIndex(where: { $0.id == id }),
            value.current.turns[index].awaitingModel
        {
            guard value.current.turns[index].user == user, value.current.turns[index].state == .generating else {
                throw WriterHistoryError.invalidRecord
            }
            var next = value
            next.current.turns[index].request = request
            next.current.turns[index].model = model
            next.current.turns[index].awaitingModel = awaitingModel
            dirtyInputs.insert(id)
            try await commit(next)
            return value.current.turns[index]
        }
        guard !value.current.turns.contains(where: { $0.id == id }) else {
            throw WriterHistoryError.invalidRecord
        }
        var record = WriterRecord(
            id: id, date: Date(), user: user, request: request, model: model,
            maximumOutputTokens: maximumOutputTokens, temperature: temperature)
        record.awaitingModel = awaitingModel
        var next = value
        next.current.turns.append(record)
        dirtyInputs.insert(id)
        try await commit(next)
        try await checkpointLocked()
        guard let accepted = value.current.turns.first(where: { $0.id == id }) else {
            throw WriterHistoryError.missingTurn
        }
        return accepted
    }

    private func updateTurn(
        _ id: String, required: Bool = true, change: (inout WriterRecord) throws -> Bool
    ) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        var next = value
        if let index = next.current.turns.firstIndex(where: { $0.id == id }) {
            guard try change(&next.current.turns[index]) else { return }
            dirtyInputs.insert(id)
            try await commit(next)
        } else if var history = try await records.input(id) {
            guard let index = history.turns.firstIndex(where: { $0.id == id }) else {
                throw WriterHistoryError.missingTurn
            }
            guard try change(&history.turns[index]) else { return }
            try await records.update(history)
        } else if required {
            throw WriterHistoryError.missingTurn
        }
    }

    public func beginModelRequest(_ request: WriterModelRequest, for id: String, awaitingDispatch: Bool = false)
        async throws
    {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        guard request.input.utf8.count <= 65_536,
            let index = value.current.turns.firstIndex(where: { $0.id == id }),
            value.current.contentBytes + request.requestJSON.utf8.count
                + (request.inputMessages ?? []).reduce(0, { $0 + $1.contentBytes })
                + (request.decisionMetadata?.catalogJSON.utf8.count ?? 0) < Self.maximumBytes - 2 * 1024 * 1024,
            value.revision < UInt64.max
        else { throw WriterHistoryError.invalidRecord }
        var next = value
        var requests = next.current.turns[index].modelRequests ?? []
        guard next.current.turns[index].state == .generating,
            !requests.contains(where: { $0.id == request.id || $0.state == .generating })
        else { throw WriterHistoryError.invalidRecord }
        var admitted = request
        let observation = !requests.isEmpty
        admitted.isObservation = observation
        admitted.inputMessageID = next.current.turns[index].messageID

        admitted.awaitingDispatch = awaitingDispatch
        requests.append(admitted)
        next.current.turns[index].modelRequests = requests
        dirtyInputs.insert(id)
        try await commit(next)
        if !awaitingDispatch { try await checkpointLocked() }
    }

    public func markModelRequestDispatched(_ id: String) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        guard let input = value.current.turns.firstIndex(where: { $0.id == id }),
            let request = value.current.turns[input].modelRequests?.indices.last
        else { throw WriterHistoryError.missingTurn }
        guard value.current.turns[input].modelRequests?[request].awaitingDispatch == true else { return }
        try Task.checkCancellation()
        guard value.current.turns[input].state == .generating,
            value.current.turns[input].modelRequests?[request].state == .generating
        else { throw WriterHistoryError.invalidRecord }
        var next = value
        next.current.turns[input].modelRequests?[request].awaitingDispatch = false
        next.current.turns[input].modelRequests?[request].date = Date()
        dirtyInputs.insert(id)
        try await commit(next)
        try await checkpointLocked()
    }

    public func clearRequestLogs(requestID: String?) async throws {
        try await records.clearRequestLogs(requestID: requestID)
    }

    public func recordModelTransport(_ update: ModelRequestLogUpdate, for id: String) async throws {
        if case .request = update { try await markModelRequestDispatched(id) }
        let snapshot = try await readCurrent()
        guard let request = snapshot.current.turns.first(where: { $0.id == id })?.modelRequests?.last else {
            throw WriterHistoryError.missingTurn
        }
        try await records.writeRequestPayload(request.id, json: "", response: "", initial: false, update: update)
    }

    public func recordModelExchange(requestJSON: String?, response: String, for id: String, initial: Bool = false)
        async throws
    {
        if let requestJSON {
            let snapshot = try await readCurrent()
            guard let request = snapshot.current.turns.first(where: { $0.id == id })?.modelRequests?.last else {
                throw WriterHistoryError.missingTurn
            }
            if request.awaitingDispatch != true {
                try await records.writeRequestPayload(
                    request.id, json: requestJSON, response: response, initial: initial)
            }
        }
        try await updateTurn(id) { turn in
            guard let index = turn.modelRequests?.indices.last else { throw WriterHistoryError.missingTurn }
            turn.modelRequests?[index].requestParametersJSON = nil
            turn.modelRequests?[index].responseEventsJSON = nil
            return true
        }
    }

    /// Exact provider evidence; the original record date remains an admission timestamp.
    public func recordModelTiming(startedAt: Date, firstTokenAt: Date?, latency: Double?, for id: String) async throws {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
            firstTokenAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
            latency.map({ $0.isFinite && $0 >= 0 }) ?? true,
            (firstTokenAt == nil) == (latency == nil)
        else { throw WriterHistoryError.invalidRecord }
        try await updateTurn(id) { turn in
            guard let index = turn.modelRequests?.indices.last,
                turn.modelRequests?[index].state == .generating,
                turn.modelRequests?[index].modelRequestStartedAt == nil
            else { return false }
            turn.modelRequests?[index].modelRequestStartedAt = startedAt
            turn.modelRequests?[index].firstTokenAt = firstTokenAt
            turn.modelRequests?[index].firstTokenLatency = latency
            return true
        }
    }

    public func finishModelRequest(
        _ id: String, reason: String?, error: String? = nil, failureDiagnostic: ModelFailureDiagnostic? = nil
    ) async throws {
        try await updateTurn(id) { turn in
            guard let index = turn.modelRequests?.indices.last,
                turn.modelRequests?[index].state == .generating
            else { throw WriterHistoryError.invalidRecord }
            turn.modelRequests?[index].modelRequestCompletedAt = Date()
            turn.modelRequests?[index].state = error == nil ? .completed : .failed
            turn.modelRequests?[index].finishReason = reason
            turn.modelRequests?[index].error = error.map { String($0.prefix(4096)) }
            turn.modelRequests?[index].failureDiagnostic = failureDiagnostic
            return true
        }
        try await checkpoint()
    }

    public func recordToolCall(_ call: ModelToolCall, for id: String) async throws {
        guard call.providerID.utf8.count <= 512, call.name.utf8.count <= 64
        else { throw WriterHistoryError.invalidRecord }
        try await updateTurn(id) { turn in
            var calls = turn.toolCalls ?? []
            guard !calls.contains(where: { $0.id == call.id }) else {
                throw WriterHistoryError.capacityExceeded
            }
            calls.append(call)
            turn.toolCalls = calls
            if let index = turn.modelRequests?.indices.last {
                turn.modelRequests?[index].toolCalls.append(call)
            }
            return true
        }
    }

    public func recordHostFinalization(_ resultsJSON: String, for id: String) async throws {
        try await updateTurn(id, required: true) { turn in
            guard let invocation = turn.modelRequests?.last?.id else { throw WriterHistoryError.missingTurn }
            var rounds = turn.generationRounds ?? []
            guard !rounds.contains(where: { $0.id == invocation }) else {
                throw WriterHistoryError.invalidRecord
            }
            rounds.append(.init(id: invocation, resultsJSON: resultsJSON))
            turn.generationRounds = rounds
            return true
        }
    }

    public func recordToolOutcome(
        _ callID: String, for id: String, state: ModelToolCall.State,
        output: String? = nil, error: String? = nil, failureDiagnostic: ModelFailureDiagnostic? = nil
    ) async throws {
        guard state != .received else {
            throw WriterHistoryError.invalidRecord
        }
        try await updateTurn(id, required: false) { turn in
            // Fixed internal UI Tools are deliberately absent from model-call history.
            guard let index = turn.toolCalls?.firstIndex(where: { $0.id == callID }) else { return false }
            turn.toolCalls?[index].state = state
            turn.toolCalls?[index].output = output
            turn.toolCalls?[index].error = error.map { String($0.prefix(4096)) }
            turn.toolCalls?[index].failureDiagnostic = failureDiagnostic
            for request in turn.modelRequests?.indices ?? 0..<0 {
                if let call = turn.modelRequests?[request].toolCalls.firstIndex(where: { $0.id == callID }),
                    let outcome = turn.toolCalls?[index]
                {
                    turn.modelRequests?[request].toolCalls[call] = outcome
                }
            }
            return true
        }
    }

    public func recordTokenUsage(_ usage: ModelTokenUsage, for id: String) async throws {
        guard usage.input >= 0, usage.generated >= 0, usage.total >= 0,
            usage.cachedInput.map({ (0...usage.input).contains($0) }) ?? true,
            usage.cacheWriteInput.map({ (0...usage.input).contains($0) }) ?? true,
            (usage.cachedInput ?? 0) <= usage.input - (usage.cacheWriteInput ?? 0)
        else {
            throw WriterHistoryError.invalidRecord
        }
        try await updateTurn(id) {
            $0.tokenUsage = usage
            if let index = $0.modelRequests?.indices.last { $0.modelRequests?[index].tokenUsage = usage }
            return true
        }
    }

    public func append(_ delta: String, to id: String) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        guard let index = value.current.turns.firstIndex(where: { $0.id == id }),
            value.current.turns[index].state == .generating
        else { throw WriterHistoryError.missingTurn }
        var next = value
        var turn = next.current.turns[index]
        let directProducer = turn.modelRequests?.isEmpty ?? true
        // Direct text producers start their message on its first content event. Managed models
        // use beginModelRequest before invoking the provider, so their deltas perform no writes.
        if turn.modelRequests?.isEmpty ?? true {
            var request = WriterModelRequest(
                id: UUID().uuidString, input: turn.user,
                requestJSON: String(decoding: try JSONEncoder().encode(turn.request), as: UTF8.self))
            request.inputMessageID = turn.messageID
            request.toolCalls = turn.toolCalls ?? []
            request.tokenUsage = turn.tokenUsage

            turn.modelRequests = [request]
        }
        if directProducer {
            next.current.turns[index] = turn
            dirtyInputs.insert(id)
            try await commit(next)
            try await checkpointLocked()
            next = value
            turn = next.current.turns[index]
        }
        turn.response += delta
        if let request = turn.modelRequests?.indices.last { turn.modelRequests?[request].response += delta }
        next.current.turns[index] = turn
        dirtyInputs.insert(id)
        try await commit(next)
    }

    public func finish(
        _ id: String, state: WriterRecord.State, reason: String? = nil, error: String? = nil,
        failureDiagnostic: ModelFailureDiagnostic? = nil
    ) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        guard let index = value.current.turns.firstIndex(where: { $0.id == id }), state != .generating else {
            throw WriterHistoryError.missingTurn
        }
        var next = value
        dirtyInputs.insert(id)
        next.current.turns[index].state = state
        next.current.turns[index].finishReason = reason
        next.current.turns[index].error = error.map { String($0.prefix(4096)) }
        next.current.turns[index].failureDiagnostic = failureDiagnostic
        if next.current.turns[index].modelRequests?.isEmpty ?? true,
            !(next.current.turns[index].toolCalls?.isEmpty ?? true)
        {
            let turn = next.current.turns[index]
            var request = WriterModelRequest(
                id: UUID().uuidString, input: turn.user,
                requestJSON: String(decoding: try JSONEncoder().encode(turn.request), as: UTF8.self))
            request.response = turn.response
            request.toolCalls = turn.toolCalls ?? []
            request.tokenUsage = turn.tokenUsage
            next.current.turns[index].modelRequests = [request]
        }
        if let request = next.current.turns[index].modelRequests?.indices.last,
            next.current.turns[index].modelRequests?[request].state == .generating
        {
            next.current.turns[index].modelRequests?[request].modelRequestCompletedAt = Date()
            next.current.turns[index].modelRequests?[request].state = state
            next.current.turns[index].modelRequests?[request].finishReason = reason
            let failure = next.current.turns[index].error
            next.current.turns[index].modelRequests?[request].error = failure
            next.current.turns[index].modelRequests?[request].failureDiagnostic = failureDiagnostic
        }
        do {
            try await commit(next)
            try await checkpointLocked()

            var window = value
            window.current = try await records.window(
                value.current.id, preserving: value.current.turns.filter { $0.state == .generating })
            try await commit(window)

        } catch {
            // The actual terminal state remains in memory; later checkpoint can retry it.
            throw error
        }
    }

    public func recordExecutionFailure(_ error: String, for id: String) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        guard let index = value.current.turns.firstIndex(where: { $0.id == id }) else { return }
        var next = value
        next.current.turns[index].executionError = String(error.prefix(4096))
        try await commit(next)
    }

}

extension WriterHistorySnapshot {
    /// Checked once per model invocation, never once per streaming delta.
    public var contentBytes: Int {
        turns.reduce(0) { total, turn in
            let requests = (turn.modelRequests ?? []).reduce(0) { sum, request in
                sum + request.requestJSON.utf8.count + request.input.utf8.count + request.response.utf8.count
                    + (request.inputMessages ?? []).reduce(0, { $0 + $1.contentBytes })
                    + (request.decisionMetadata?.catalogJSON.utf8.count ?? 0)
                    + request.toolCalls.reduce(0) { $0 + $1.argumentsJSON.utf8.count + ($1.output?.utf8.count ?? 0) }
            }
            return total + turn.user.utf8.count + turn.response.utf8.count + requests
                + turn.request.reduce(0) { $0 + $1.content.utf8.count }
                + (turn.generationRounds ?? []).reduce(0) { $0 + $1.resultsJSON.utf8.count }
        }
    }
}

extension WriterJournal {
    public func validate() throws {
        guard revision < UInt64.max
        else { throw WriterHistoryError.invalidRecord }
    }

}
