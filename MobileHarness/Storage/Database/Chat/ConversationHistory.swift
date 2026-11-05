import Foundation
import StorageCore
import StorageTasks

public actor ConversationHistoryStore {
    public static let maximumBytes = 32 * 1024 * 1024
    public private(set) var lastCheckpointError: String?
    public nonisolated let tasks: any TaskRepository
    private var nextMemoryDialog: Int64 = 0
    private func newMemoryDialog() throws -> StoredConversation {
        let greatest =
            ([value.current] + value.past).compactMap { BusinessRecordID(rawValue: $0.id) }.filter {
                $0.kind == .dialog
            }.map(\.number).max() ?? 0
        nextMemoryDialog = max(nextMemoryDialog, greatest)
        guard nextMemoryDialog < Int64.max else { throw RecordStorageError.invalidRecord }
        nextMemoryDialog += 1
        return StoredConversation(id: "dialog_\(nextMemoryDialog)")
    }
    public private(set) var contextIdentity: String?
    private let records: ConversationRecordStore?
    private let capture: (@Sendable () async throws -> ConversationCheckpoint)?
    private let canArchive: (@Sendable () async throws -> Void)?
    private let restore: (@Sendable (ConversationArchive, Data?) async throws -> Void)?
    private var value = ConversationArchive()
    private var readToken = ConversationReadToken(value: UUID().uuidString)
    private var savedID: String?
    private var savedRevision: UInt64?
    private var savedRecovery: Data?
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
        guard writers.count < 16 else { throw ConversationHistoryError.busy }
        await withCheckedContinuation { writers.append($0) }
    }

    private func releaseWrite() {
        if writers.isEmpty { writing = false } else { writers.removeFirst().resume() }
    }

    private var contextLoad: (@Sendable () async throws -> ConversationArchive)?
    private var contextCommit: (@Sendable (ConversationArchive) async throws -> Void)?
    public init(records: ConversationRecordStore? = nil) {
        self.records = records
        tasks = records?.tasks ?? MemoryTaskRepository()
        capture = nil
        canArchive = nil
        restore = nil
        contextIdentity = nil
        contextLoad = nil
        contextCommit = nil
    }
    /// Transactional projection over the Agent-owned authoritative context; no second writer.
    public init(
        contextIdentity: String? = nil, records: ConversationRecordStore? = nil,
        capture: (@Sendable () async throws -> ConversationCheckpoint)? = nil,
        canArchive: (@Sendable () async throws -> Void)? = nil,
        restore: (@Sendable (ConversationArchive, Data?) async throws -> Void)? = nil,
        contextLoad: @escaping @Sendable () async throws -> ConversationArchive,
        contextCommit: @escaping @Sendable (ConversationArchive) async throws -> Void
    ) {
        self.records = records
        tasks = records?.tasks ?? MemoryTaskRepository()
        self.capture = capture
        self.canArchive = canArchive
        self.restore = restore
        self.contextIdentity = contextIdentity
        self.contextLoad = contextLoad
        self.contextCommit = contextCommit
    }

    /// The host attaches the authoritative context without importing another journal.
    public func attachContext(
        identity: String,
        load: @escaping @Sendable () async throws -> ConversationArchive,
        commit: @escaping @Sendable (ConversationArchive) async throws -> Void
    ) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        guard contextIdentity == nil || contextIdentity == identity else { throw ConversationHistoryError.busy }
        let authoritative = try await load()
        guard authoritative.version == 4 else { throw DocumentStorageError.unsupportedVersion }
        contextIdentity = identity
        contextLoad = load
        contextCommit = commit
        value = authoritative
        loaded = true
        readToken = ConversationReadToken(value: UUID().uuidString)
    }
    private func load() async throws {
        if !loaded, let records {
            if let saved = try await records.loadCurrent() {
                guard saved.version == 1 else { throw DocumentStorageError.unsupportedVersion }
                savedID = saved.conversation.id
                savedRevision = saved.revision
                savedRecovery = saved.recovery
                value.current = saved.conversation
                value.revision = saved.revision
                var recovered = false
                for index in value.current.turns.indices where value.current.turns[index].state == .generating {
                    recovered = true
                    dirtyInputs.insert(value.current.turns[index].id)
                    value.current.turns[index].state = .interrupted
                    value.current.turns[index].error = "Interrupted; actions are never replayed"
                    for request in value.current.turns[index].modelRequests?.indices ?? 0..<0
                    where value.current.turns[index].modelRequests?[request].state == .generating {
                        value.current.turns[index].modelRequests?[request].state = .interrupted
                    }
                }
                if recovered {
                    guard value.revision < UInt64.max else { throw ConversationHistoryError.capacityExceeded }
                    value.revision += 1
                }
                if let restore { try await restore(value, saved.recovery) }
            }
            loaded = true
        }
        if let contextLoad {
            let latest = try await contextLoad()
            guard latest.version == 4 else { throw DocumentStorageError.unsupportedVersion }
            if latest.revision != value.revision {
                readToken = ConversationReadToken(value: UUID().uuidString)
            }
            value = latest
        }
        if needsCurrentSynchronization { try await synchronizeCurrentLocked() }
        if value.current.id == "draft" {
            guard value.current.turns.isEmpty, value.past.isEmpty else { throw DocumentStorageError.invalidFile }
            var initialized = value
            if let records {
                guard let current = try await records.loadCurrent() else { throw RecordStorageError.missingRecord }
                initialized.current = current.conversation
            } else {
                initialized.current = try newMemoryDialog()
            }
            try await commit(initialized)
        }
        loaded = true
    }
    /// Called only at operation boundaries or while recovering a committed rotation, never per delta.
    private func synchronizeCurrentLocked() async throws {
        guard let records else { return }
        let current = try await records.currentMetadata()
        guard needsCurrentSynchronization || current.id != value.current.id else { return }
        if !needsCurrentSynchronization {
            guard dirtyInputs.isEmpty, !value.current.turns.contains(where: { $0.state == .generating }) else {
                throw ConversationHistoryError.conflict
            }
        }
        needsCurrentSynchronization = true
        guard let saved = try await records.loadCurrent() else { throw RecordStorageError.missingRecord }
        var next = value
        next.current = saved.conversation
        try await commit(next)
        guard value.current.id == saved.conversation.id else { throw ConversationHistoryError.conflict }
        dirtyInputs.removeAll()
        savedID = saved.conversation.id
        savedRevision = value.revision
        savedRecovery = saved.recovery
        needsCurrentSynchronization = false
    }

    private func commit(_ candidate: ConversationArchive) async throws {
        var next = candidate
        guard value.revision < UInt64.max else { throw ConversationHistoryError.capacityExceeded }
        next.revision = value.revision + 1
        if let contextCommit { try await contextCommit(next) }
        if let contextLoad { value = try await contextLoad() } else { value = next }
        readToken = ConversationReadToken(value: UUID().uuidString)
    }
    private func checkpointLocked() async throws {
        guard let records else { return }
        do {
            try value.validate()
            var snapshot = try await capture?() ?? .init(conversation: value.current, revision: value.revision)
            snapshot.changedInputs = dirtyInputs
            guard snapshot.conversation.id == value.current.id else { throw ConversationHistoryError.conflict }
            if snapshot.conversation.id == savedID && snapshot.revision == savedRevision
                && snapshot.recovery == savedRecovery
            {
                guard try await records.isCurrent(snapshot.conversation.id) else {
                    throw ConversationHistoryError.conflict
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
                    attachedIdentity = true
                }
            }
            if attachedIdentity { try await commit(next) }
            dirtyInputs.subtract(snapshot.changedInputs ?? [])
            savedID = snapshot.conversation.id
            savedRevision = value.revision
            savedRecovery = snapshot.recovery
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
    public func listConversations() async throws -> [StoredConversation] {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if let records { return [try await records.currentMetadata()] + (try await records.list()) }
        return [value.current] + value.past
    }
    public func conversation(_ id: String) async throws -> StoredConversation {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if value.current.id == id { return value.current }
        if let records {
            do { return try await records.read(id) } catch RecordStorageError.missingRecord {
                throw ConversationHistoryError.missingTurn
            }
        }
        guard let saved = value.past.first(where: { $0.id == id }) else { throw ConversationHistoryError.missingTurn }
        return saved
    }
    public func page(_ id: String, after: UInt64 = 0, taskID: String? = nil) async throws -> StoredConversation {
        if let records {
            try await acquireWrite()
            defer { releaseWrite() }
            try await load()
            return try await records.page(id, after: after, taskID: taskID)
        }
        return try await conversation(id)
    }
    public func message(_ id: String) async throws -> StoredConversation {
        guard let records else { throw ConversationHistoryError.missingTurn }
        return try await records.message(id)
    }
    public func requestPreviews(_ id: String, after: UInt64) async throws -> [MessagePreview] {
        guard let records else { throw ConversationHistoryError.missingTurn }
        return try await records.requestPreviews(id, after: after)
    }
    public func requestCount(_ id: String) async throws -> Int {
        if let records { return try await records.requestCount(id) }
        return try await conversation(id).turns.reduce(0) { $0 + ($1.modelRequests?.count ?? 0) }
    }
    public func dialogMetadata(_ id: String) async throws -> StoredConversation {
        if let records {
            do { return try await records.dialogMetadata(id) } catch RecordStorageError.missingRecord {
                throw ConversationHistoryError.missingTurn
            }
        }
        return try await conversation(id)
    }
    public func titleExcerpt(_ id: String, positions: [Int]) async throws -> StoredConversation {
        if let records { return try await records.titleExcerpt(id, positions: positions) }
        var result = try await conversation(id)
        result.turns = positions.compactMap { result.turns.indices.contains($0) ? result.turns[$0] : nil }
        return result
    }
    public func timelinePage(_ id: String, offset: Int, limit: Int) async throws -> (
        items: [ConversationHistoryItem], total: Int
    ) {
        if let records {
            do {
                let page = try await records.page(id, limit: limit, offset: offset)
                return (try page.indexedHistory(), try await records.repository.timelineCount(dialog: id))
            } catch RecordStorageError.missingRecord { throw ConversationHistoryError.missingTurn }
        }
        let all = try await conversation(id).indexedHistory()
        return (Array(all.dropFirst(offset).prefix(limit)), all.count)
    }
    public func archivePage(before: Int64) async throws -> [StoredConversation] {
        try await records?.list(before: before) ?? []
    }
    public func snapshot() async throws -> ConversationArchive {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        var result = value
        if let records { result.past = try await records.list() }
        return result
    }

    /// Identity-only duplicate lookup across this Agent's dialogs; never imports old dialog context.
    public func containsInput(_ id: String) async throws -> Bool {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if value.current.turns.contains(where: { $0.id == id }) { return true }
        if let records { return try await records.containsInput(id) }
        return value.past.contains { $0.turns.contains { $0.id == id } }
    }
    /// Reads records and a fence atomically, without selecting model context.
    public func readCurrent() async throws -> ConversationReadSnapshot {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        return ConversationReadSnapshot(current: value.current, token: readToken)
    }

    /// Admits user text before a model request exists, under one current-conversation write fence.
    public func admitUserInput(id: String, user: String, model: String) async throws -> ConversationRecord {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        guard !value.current.turns.contains(where: { $0.id == id }) else {
            throw ConversationHistoryError.invalidRecord
        }
        return try await beginLocked(
            id: id, user: user, request: [], model: model,
            maximumOutputTokens: nil, temperature: 0.7, awaitingModel: true)
    }

    /// Persists the caller's exact request, rejecting intervening mutations.
    public func begin(
        id: String, user: String, request: [ConversationMessage], expecting token: ConversationReadToken,
        model: String, maximumOutputTokens: Int? = nil, temperature: Double = 0.7, awaitingModel: Bool = false
    ) async throws -> ConversationRecord {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        guard token == readToken else { throw ConversationHistoryError.conflict }
        return try await beginLocked(
            id: id, user: user, request: request, model: model,
            maximumOutputTokens: maximumOutputTokens, temperature: temperature, awaitingModel: awaitingModel)
    }

    private func beginLocked(
        id: String, user: String, request: [ConversationMessage], model: String,
        maximumOutputTokens: Int?, temperature: Double, awaitingModel: Bool
    ) async throws -> ConversationRecord {
        guard user.utf8.count <= 4096, model.utf8.count <= 512,
            request.count <= 514,
            request.allSatisfy({ $0.content.utf8.count <= ($0.role == .system ? 65536 : 262144) }),
            temperature.isFinite, maximumOutputTokens.map({ $0 > 0 }) ?? true
        else { throw ConversationHistoryError.invalidRecord }

        if let index = value.current.turns.firstIndex(where: { $0.id == id }),
            value.current.turns[index].awaitingModel
        {
            guard value.current.turns[index].user == user, value.current.turns[index].state == .generating else {
                throw ConversationHistoryError.invalidRecord
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
            throw ConversationHistoryError.invalidRecord
        }
        var record = ConversationRecord(
            id: id, date: Date(), user: user, request: request, model: model,
            maximumOutputTokens: maximumOutputTokens, temperature: temperature)
        record.historyOrder = value.revision + 1
        record.awaitingModel = awaitingModel
        var next = value
        next.current.turns.append(record)
        dirtyInputs.insert(id)
        try await commit(next)
        try await checkpointLocked()
        guard let accepted = value.current.turns.first(where: { $0.id == id }) else {
            throw ConversationHistoryError.missingTurn
        }
        return accepted
    }

    private func updateTurn(
        _ id: String, required: Bool = true, change: (inout ConversationRecord) throws -> Bool
    ) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        for attempt in 0..<4 {
            try await load()
            var next = value
            if let index = next.current.turns.firstIndex(where: { $0.id == id }) {
                guard try change(&next.current.turns[index]) else { return }
            } else if let archive = next.past.firstIndex(where: { $0.turns.contains(where: { $0.id == id }) }),
                let index = next.past[archive].turns.firstIndex(where: { $0.id == id })
            {
                guard try change(&next.past[archive].turns[index]) else { return }
            } else if let records, var conversation = try await records.input(id) {
                guard let index = conversation.turns.firstIndex(where: { $0.id == id }) else {
                    throw ConversationHistoryError.missingTurn
                }
                guard try change(&conversation.turns[index]) else { return }
                try await records.update(conversation)
                return
            } else {
                if required { throw ConversationHistoryError.missingTurn }
                return
            }
            do {
                dirtyInputs.insert(id)
                try await commit(next)
                return
            } catch ConversationHistoryError.conflict where contextLoad != nil && attempt < 3 {
                continue
            }
        }
    }

    public func beginModelRequest(_ request: ConversationModelRequest, for id: String) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        guard request.input.utf8.count <= 65_536,
            let index = value.current.turns.firstIndex(where: { $0.id == id }),
            value.current.contentBytes + request.requestJSON.utf8.count
                + (request.decisionMetadata?.catalogJSON.utf8.count ?? 0) < Self.maximumBytes - 2 * 1024 * 1024,
            value.revision < UInt64.max
        else { throw ConversationHistoryError.invalidRecord }
        var next = value
        var requests = next.current.turns[index].modelRequests ?? []
        guard next.current.turns[index].state == .generating,
            !requests.contains(where: { $0.id == request.id || $0.state == .generating })
        else { throw ConversationHistoryError.invalidRecord }
        var admitted = request
        admitted.historyOrder = value.revision + 1
        let observation = !requests.isEmpty
        admitted.isObservation = observation
        admitted.inputMessageID = next.current.turns[index].messageID
        if let records {
            if observation {
                admitted.inputMessageID = try await records.beginMessage(
                    dialog: value.current.id,
                    identity: .init(
                        clientID: request.id, inputID: id, role: "user", kind: "observation",
                        order: admitted.historyOrder, date: admitted.date, taskID: request.historyTaskID,
                        replyTo: requests.last?.messageID))
            }
            admitted.messageID = try await records.beginMessage(
                dialog: value.current.id,
                identity: .init(
                    clientID: request.id, inputID: id, role: "assistant", kind: "response",
                    order: admitted.historyOrder, date: admitted.date, taskID: request.historyTaskID,
                    replyTo: admitted.inputMessageID, detail: try JSONEncoder().encode(admitted)))
        }
        requests.append(admitted)
        next.current.turns[index].modelRequests = requests
        dirtyInputs.insert(id)
        try await commit(next)
        if observation { try await checkpointLocked() }
    }

    public func recordModelExchange(requestJSON: String?, response: String, for id: String) async throws {
        try await updateTurn(id) { turn in
            guard let index = turn.modelRequests?.indices.last else { throw ConversationHistoryError.missingTurn }
            turn.modelRequests?[index].requestParametersJSON = requestJSON
            turn.modelRequests?[index].responseEventsJSON = response
            return true
        }
    }

    /// Exact provider evidence; the original record date remains an admission timestamp.
    public func recordModelTiming(startedAt: Date, firstTokenAt: Date?, latency: Double?, for id: String) async throws {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
            firstTokenAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
            latency.map({ $0.isFinite && $0 >= 0 }) ?? true,
            (firstTokenAt == nil) == (latency == nil)
        else { throw ConversationHistoryError.invalidRecord }
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
        _ id: String, reason: String?, error: String? = nil, failureDiagnostic: ConversationFailureDiagnostic? = nil
    ) async throws {
        try await updateTurn(id) { turn in
            guard let index = turn.modelRequests?.indices.last,
                turn.modelRequests?[index].state == .generating
            else { throw ConversationHistoryError.invalidRecord }
            turn.modelRequests?[index].modelRequestCompletedAt = Date()
            turn.modelRequests?[index].state = error == nil ? .completed : .failed
            turn.modelRequests?[index].finishReason = reason
            turn.modelRequests?[index].error = error.map { String($0.prefix(4096)) }
            turn.modelRequests?[index].failureDiagnostic = failureDiagnostic
            return true
        }
        try await checkpoint()
    }

    public func recordToolDefinitions(_ definitions: [String], for id: String) async throws {
        guard definitions.count <= 128, definitions.reduce(0, { $0 + $1.utf8.count }) <= 65536 else {
            throw ConversationHistoryError.capacityExceeded
        }
        try await updateTurn(id) {
            $0.toolDefinitions = definitions
            $0.toolCalls = []
            return true
        }
    }

    public func recordToolCall(_ call: ConversationToolCall, for id: String) async throws {
        guard call.providerID.utf8.count <= 512, call.name.utf8.count <= 64
        else { throw ConversationHistoryError.invalidRecord }
        try await updateTurn(id) { turn in
            var calls = turn.toolCalls ?? []
            guard !calls.contains(where: { $0.id == call.id }) else {
                throw ConversationHistoryError.capacityExceeded
            }
            calls.append(call)
            turn.toolCalls = calls
            if let index = turn.modelRequests?.indices.last {
                turn.modelRequests?[index].toolCalls.append(call)
            }
            return true
        }
    }

    public func recordGenerationRound(_ round: ConversationGenerationRound, for id: String) async throws {
        try await updateTurn(id, required: true) { turn in
            var rounds = turn.generationRounds ?? []
            guard !rounds.contains(where: { $0.id == round.id }) else {
                throw ConversationHistoryError.invalidRecord
            }
            rounds.append(round)
            turn.generationRounds = rounds
            return true
        }
    }

    public func recordToolOutcome(
        _ callID: String, for id: String, state: ConversationToolCall.State,
        output: String? = nil, error: String? = nil, failureDiagnostic: ConversationFailureDiagnostic? = nil
    ) async throws {
        guard state != .received else {
            throw ConversationHistoryError.invalidRecord
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

    public func recordTokenUsage(_ usage: ConversationTokenUsage, for id: String) async throws {
        guard usage.input >= 0, usage.generated >= 0, usage.total >= 0,
            usage.cachedInput.map({ (0...usage.input).contains($0) }) ?? true,
            usage.cacheWriteInput.map({ (0...usage.input).contains($0) }) ?? true,
            (usage.cachedInput ?? 0) <= usage.input - (usage.cacheWriteInput ?? 0)
        else {
            throw ConversationHistoryError.invalidRecord
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
        else { throw ConversationHistoryError.missingTurn }
        var next = value
        var turn = next.current.turns[index]
        // Direct text producers start their message on its first content event. Managed models
        // use beginModelRequest before invoking the provider, so their deltas perform no writes.
        if turn.modelRequests?.isEmpty ?? true {
            var request = ConversationModelRequest(
                id: UUID().uuidString, input: turn.user,
                requestJSON: String(decoding: try JSONEncoder().encode(turn.request), as: UTF8.self))
            request.historyOrder = value.revision + 1
            request.inputMessageID = turn.messageID
            request.toolCalls = turn.toolCalls ?? []
            request.tokenUsage = turn.tokenUsage
            if let records {
                request.messageID = try await records.beginMessage(
                    dialog: value.current.id,
                    identity: .init(
                        clientID: request.id, inputID: id, role: "assistant", kind: "response",
                        order: request.historyOrder, date: request.date, replyTo: turn.messageID,
                        detail: try JSONEncoder().encode(request)))
            }
            turn.modelRequests = [request]
        }
        turn.response += delta
        if let request = turn.modelRequests?.indices.last { turn.modelRequests?[request].response += delta }
        next.current.turns[index] = turn
        dirtyInputs.insert(id)
        try await commit(next)
    }

    public func finish(
        _ id: String, state: ConversationRecord.State, reason: String? = nil, error: String? = nil,
        failureDiagnostic: ConversationFailureDiagnostic? = nil
    ) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        guard let index = value.current.turns.firstIndex(where: { $0.id == id }), state != .generating else {
            throw ConversationHistoryError.missingTurn
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
            var request = ConversationModelRequest(
                id: UUID().uuidString, input: turn.user,
                requestJSON: String(decoding: try JSONEncoder().encode(turn.request), as: UTF8.self))
            request.historyOrder = value.revision + 1
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
            if let records {
                var window = value
                window.current = try await records.window(
                    value.current.id, preserving: value.current.turns.filter { $0.state == .generating })
                try await commit(window)
            }
        } catch {
            // The actual terminal state remains in memory; later checkpoint can retry it.
            throw error
        }
    }

    /// Requires producer cancellation/cleanup before archival. An empty conversation is not archived.
    public func startNew() async throws -> StoredConversation? {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        guard !value.current.turns.contains(where: { $0.state == .generating }) else {
            throw ConversationHistoryError.busy
        }
        guard !value.current.turns.isEmpty else { return nil }
        try await canArchive?()
        var archived = value.current
        archived.archivedAt = Date()
        if let records {
            var snapshot = try await capture?() ?? .init(conversation: archived, revision: value.revision)
            snapshot.conversation = archived
            _ = try await records.rotate(snapshot)
            // The SQL transaction has committed. Never retry it just because memory publication fails.
            needsCurrentSynchronization = true
            dirtyInputs.removeAll()
            try await synchronizeCurrentLocked()
        } else {
            var next = value
            next.current = try newMemoryDialog()
            next.past.insert(archived, at: 0)
            try await commit(next)
        }
        return archived
    }

    public func setTitle(_ title: String?, error: String? = nil, for id: String) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if let records {
            if let title, title.isEmpty || title.count > 80 { throw ConversationHistoryError.invalidRecord }
            try await records.setTitle(title, error: error.map { String($0.prefix(4096)) }, for: id)
            return
        }
        guard let index = value.past.firstIndex(where: { $0.id == id }) else {
            throw ConversationHistoryError.invalidRecord
        }
        if let title {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 80 else {
                throw ConversationHistoryError.invalidRecord
            }
        }
        var next = value
        next.past[index].summaryTitle = title
        next.past[index].titleError = error.map { String($0.prefix(4096)) }
        try await commit(next)
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

    public func deleteArchived(_ id: String) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if let records {
            try await records.delete(id)
            return
        }
        var next = value
        next.past.removeAll { $0.id == id }
        try await commit(next)
    }
}

extension StoredConversation {
    /// Checked once per model invocation, never once per streaming delta.
    public var contentBytes: Int {
        turns.reduce(0) { total, turn in
            let requests = (turn.modelRequests ?? []).reduce(0) { sum, request in
                sum + request.requestJSON.utf8.count + request.input.utf8.count + request.response.utf8.count
                    + (request.decisionMetadata?.catalogJSON.utf8.count ?? 0)
                    + request.toolCalls.reduce(0) { $0 + $1.argumentsJSON.utf8.count + ($1.output?.utf8.count ?? 0) }
            }
            return total + turn.user.utf8.count + turn.response.utf8.count + requests
                + turn.request.reduce(0) { $0 + $1.content.utf8.count }
                + (turn.toolDefinitions ?? []).reduce(0) { $0 + $1.utf8.count }
                + (turn.generationRounds ?? []).reduce(0) { $0 + $1.resultsJSON.utf8.count }
        }
    }
    public func validateCompressions() throws {
        guard Set(taskCompressions.map(\.taskID)).count == taskCompressions.count else {
            throw ConversationHistoryError.invalidRecord
        }
        let requests = turns.flatMap { turn in
            (turn.modelRequests ?? []).map { (ConversationHistoryReference(inputID: turn.id, requestID: $0.id), $0) }
        }.sorted { $0.1.historyOrder < $1.1.historyOrder }
        guard Set(requests.map { $0.0.requestID }).count == requests.count,
            Set(requests.map { $0.1.historyOrder }).count == requests.count,
            requests.allSatisfy({ $0.1.historyOrder > 0 })
        else {
            throw ConversationHistoryError.invalidRecord
        }
        for compression in taskCompressions {
            let owned = requests.filter { $0.1.historyTaskID == compression.taskID }
            guard compression.status != .generating, !compression.sources.isEmpty,
                compression.sources.count <= 8192,
                compression.goal.utf8.count <= 4096,
                (compression.reportedSummary?.utf8.count ?? 0) <= 4096,
                (compression.failure?.utf8.count ?? 0) <= 16384,
                isWindow
                    ? Set(owned.map({ $0.0 })).isSubset(of: Set(compression.sources))
                    : owned.map({ $0.0 }) == compression.sources,
                owned.allSatisfy({ $0.1.state != .generating })
            else { throw ConversationHistoryError.invalidRecord }
        }
    }

    /// Replace only indexed sources, at the first source; intervening unrelated requests survive.
    public func indexedHistory() throws -> [ConversationHistoryItem] {
        try validateCompressions()
        let compressions = Dictionary(uniqueKeysWithValues: taskCompressions.map { ($0.taskID, $0) })
        var emitted: Set<String> = []
        let requests = turns.flatMap { turn in (turn.modelRequests ?? []).map { (turn, $0) } }
            .sorted { $0.1.historyOrder < $1.1.historyOrder }
        return requests.compactMap { turn, request -> ConversationHistoryItem? in
            if let task = request.historyTaskID, let compression = compressions[task] {
                return emitted.insert(task).inserted ? .task(compression) : nil
            }
            return .request(input: turn, request: request)
        }
    }
}

extension ConversationArchive {
    public func validate() throws {
        guard version == 4, revision < UInt64.max,
            Set(([current] + past).map(\.id)).count == past.count + 1
        else { throw ConversationHistoryError.invalidRecord }
        for conversation in [current] + past { try conversation.validateCompressions() }
    }

    public mutating func assignHistoryTask(_ taskID: String, inputID: String, requestID: String) throws {
        guard let turn = current.turns.firstIndex(where: { $0.id == inputID }),
            let request = current.turns[turn].modelRequests?.firstIndex(where: { $0.id == requestID }),
            current.turns[turn].modelRequests?[request].historyTaskID == nil
        else { throw ConversationHistoryError.invalidRecord }
        current.turns[turn].modelRequests?[request].historyTaskID = taskID
        guard revision < UInt64.max else { throw ConversationHistoryError.capacityExceeded }
        revision += 1
    }
}
