import Foundation
import StorageCore
import StorageTasks

public actor AssistantHistoryStore {
    public static let maximumBytes = 32 * 1024 * 1024
    public private(set) var lastCheckpointError: String?
    public nonisolated let tasks: any AssistantTaskRepository
    private var nextMemoryDialog: Int64 = 0
    private func newMemoryDialog() throws -> AssistantConversation {
        let greatest =
            ([value.current] + value.past).compactMap { BusinessRecordID(rawValue: $0.id) }.filter {
                $0.kind == .dialog
            }.map(\.number).max() ?? 0
        nextMemoryDialog = max(nextMemoryDialog, greatest)
        guard nextMemoryDialog < Int64.max else { throw RecordStorageError.invalidRecord }
        nextMemoryDialog += 1
        return AssistantConversation(id: "dialog_\(nextMemoryDialog)")
    }
    public private(set) var contextIdentity: String?
    private let records: AssistantRecordStore?
    private let capture: (@Sendable () async throws -> AssistantCheckpoint)?
    private let canArchive: (@Sendable () async throws -> Void)?
    private let restore: (@Sendable (AssistantArchive) async throws -> Void)?
    private var value = AssistantArchive()
    private var readToken = AssistantReadToken(value: UUID().uuidString)
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
        guard writers.count < 16 else { throw AssistantHistoryError.busy }
        await withCheckedContinuation { writers.append($0) }
    }

    private func releaseWrite() {
        if writers.isEmpty { writing = false } else { writers.removeFirst().resume() }
    }

    private var contextLoad: (@Sendable () async throws -> AssistantArchive)?
    private var contextCommit: (@Sendable (AssistantArchive) async throws -> Void)?
    public init(records: AssistantRecordStore? = nil) {
        self.records = records
        tasks = records?.tasks ?? MemoryAssistantTaskRepository()
        capture = nil
        canArchive = nil
        restore = nil
        contextIdentity = nil
        contextLoad = nil
        contextCommit = nil
    }
    /// Transactional projection over the Agent-owned authoritative context; no second writer.
    public init(
        contextIdentity: String? = nil, records: AssistantRecordStore? = nil,
        capture: (@Sendable () async throws -> AssistantCheckpoint)? = nil,
        canArchive: (@Sendable () async throws -> Void)? = nil,
        restore: (@Sendable (AssistantArchive) async throws -> Void)? = nil,
        contextLoad: @escaping @Sendable () async throws -> AssistantArchive,
        contextCommit: @escaping @Sendable (AssistantArchive) async throws -> Void
    ) {
        self.records = records
        tasks = records?.tasks ?? MemoryAssistantTaskRepository()
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
        load: @escaping @Sendable () async throws -> AssistantArchive,
        commit: @escaping @Sendable (AssistantArchive) async throws -> Void
    ) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        guard contextIdentity == nil || contextIdentity == identity else { throw AssistantHistoryError.busy }
        let authoritative = try await load()
        guard authoritative.version == 4 else { throw DocumentStorageError.unsupportedVersion }
        contextIdentity = identity
        contextLoad = load
        contextCommit = commit
        value = authoritative
        loaded = true
        readToken = AssistantReadToken(value: UUID().uuidString)
    }
    private func load() async throws {
        if !loaded, let records {
            if let saved = try await records.loadCurrent() {
                guard saved.version == 1 else { throw DocumentStorageError.unsupportedVersion }
                savedID = saved.conversation.id
                savedRevision = saved.revision
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
                    guard value.revision < UInt64.max else { throw AssistantHistoryError.capacityExceeded }
                    value.revision += 1
                }
                if let restore { try await restore(value) }
            }
            loaded = true
        }
        if let contextLoad {
            let latest = try await contextLoad()
            guard latest.version == 4 else { throw DocumentStorageError.unsupportedVersion }
            if latest.revision != value.revision {
                readToken = AssistantReadToken(value: UUID().uuidString)
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
                throw AssistantHistoryError.conflict
            }
        }
        needsCurrentSynchronization = true
        guard let saved = try await records.loadCurrent() else { throw RecordStorageError.missingRecord }
        var next = value
        next.current = saved.conversation
        try await commit(next)
        guard value.current.id == saved.conversation.id else { throw AssistantHistoryError.conflict }
        dirtyInputs.removeAll()
        savedID = saved.conversation.id
        savedRevision = value.revision
        needsCurrentSynchronization = false
    }

    private func commit(_ candidate: AssistantArchive) async throws {
        var next = candidate
        guard value.revision < UInt64.max else { throw AssistantHistoryError.capacityExceeded }
        next.revision = value.revision + 1
        if let contextCommit { try await contextCommit(next) }
        if let contextLoad { value = try await contextLoad() } else { value = next }
        readToken = AssistantReadToken(value: UUID().uuidString)
    }
    private func checkpointLocked() async throws {
        guard let records else { return }
        do {
            try value.validate()
            var snapshot = try await capture?() ?? .init(conversation: value.current, revision: value.revision)
            snapshot.changedInputs = dirtyInputs
            guard snapshot.conversation.id == value.current.id else { throw AssistantHistoryError.conflict }
            if snapshot.conversation.id == savedID && snapshot.revision == savedRevision {
                guard try await records.isCurrent(snapshot.conversation.id) else {
                    throw AssistantHistoryError.conflict
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
    public func completeForegroundTask(
        _ taskID: String, goal: String, summary: String, finishedAt: Date, inputID: String, requestID: String?,
        publish: @Sendable (AssistantArchive, @escaping @Sendable () async throws -> Void) async throws -> Void
    ) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if let requestID {
            guard
                let request = value.current.turns.first(where: { $0.id == inputID })?.modelRequests?.first(where: {
                    $0.id == requestID
                }), request.historyTaskID == taskID, request.awaitingDispatch != true
            else { throw RecordStorageError.conflict }
        }
        try await checkpointLocked()

        let sources: [AssistantHistoryReference]
        if let records {
            sources = try await records.tasks.taskSources(taskID).map {
                AssistantHistoryReference(inputID: $0.inputID, requestID: $0.requestID)
            }
        } else {
            sources = value.current.turns.flatMap { turn in
                (turn.modelRequests ?? []).filter { $0.historyTaskID == taskID && $0.awaitingDispatch != true }.map {
                    ($0.historyOrder, AssistantHistoryReference(inputID: turn.id, requestID: $0.id))
                }
            }.sorted { $0.0 < $1.0 }.map(\.1)
        }
        if let requestID, !sources.contains(where: { $0.requestID == requestID }) {
            throw RecordStorageError.conflict
        }
        let compression = AssistantTaskCompression(
            taskID: taskID, goal: goal, status: .completed, reportedSummary: summary, failure: nil,
            completedAt: finishedAt, sources: sources, closedAtAction: true)
        var next = value
        guard next.revision < UInt64.max else { throw AssistantHistoryError.capacityExceeded }
        next.revision += 1
        if !sources.isEmpty { next.current.taskCompressions.append(compression) }
        try next.validate()
        let completion = try TaskCompressionRecord(
            id: taskID, goal: goal, status: "completed", summary: summary, failure: nil, finishedAt: finishedAt,
            sources: sources.map(\.requestID), detail: JSONEncoder().encode(compression))
        let dialog = next.current.id
        let summaries = records?.tasks
        let tasks = tasks
        try await publish(next) {
            if let summaries {
                try await summaries.completeTask(completion, dialog: dialog, endingRequest: requestID)
            } else {
                try await tasks.endTask(taskID, status: "completed", failure: nil, finishedAt: finishedAt)
            }
        }
        value = next
        readToken = AssistantReadToken(value: UUID().uuidString)
    }
    public func listConversations() async throws -> [AssistantConversation] {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if let records { return [try await records.currentMetadata()] + (try await records.list()) }
        return [value.current] + value.past
    }
    public func conversation(_ id: String) async throws -> AssistantConversation {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if value.current.id == id { return value.current }
        if let records {
            do { return try await records.read(id) } catch RecordStorageError.missingRecord {
                throw AssistantHistoryError.missingTurn
            }
        }
        guard let saved = value.past.first(where: { $0.id == id }) else { throw AssistantHistoryError.missingTurn }
        return saved
    }
    public func page(_ id: String, after: UInt64 = 0, taskID: String? = nil) async throws -> AssistantConversation {
        if let records {
            try await acquireWrite()
            defer { releaseWrite() }
            try await load()
            return try await records.page(id, after: after, taskID: taskID)
        }
        return try await conversation(id)
    }
    public func message(_ id: String) async throws -> AssistantConversation {
        guard let records else { throw AssistantHistoryError.missingTurn }
        return try await records.message(id)
    }
    public func requestPreviews(_ id: String, after: UInt64) async throws -> [AssistantMessagePreview] {
        guard let records else { throw AssistantHistoryError.missingTurn }
        return try await records.requestPreviews(id, after: after)
    }
    public func requestCount(_ id: String) async throws -> Int {
        if let records { return try await records.requestCount(id) }
        return try await conversation(id).turns.reduce(0) { $0 + ($1.modelRequests?.count ?? 0) }
    }
    public func dialogMetadata(_ id: String) async throws -> AssistantConversation {
        if let records {
            do { return try await records.dialogMetadata(id) } catch RecordStorageError.missingRecord {
                throw AssistantHistoryError.missingTurn
            }
        }
        return try await conversation(id)
    }
    public func titleExcerpt(_ id: String, positions: [Int]) async throws -> AssistantConversation {
        if let records { return try await records.titleExcerpt(id, positions: positions) }
        var result = try await conversation(id)
        result.turns = positions.compactMap { result.turns.indices.contains($0) ? result.turns[$0] : nil }
        return result
    }
    public func timelinePage(_ id: String, offset: Int, limit: Int) async throws -> (
        items: [AssistantHistoryItem], total: Int
    ) {
        if let records {
            do {
                let page = try await records.page(id, limit: limit, offset: offset)
                return (try page.indexedHistory(), try await records.repository.timelineCount(dialog: id))
            } catch RecordStorageError.missingRecord { throw AssistantHistoryError.missingTurn }
        }
        let all = try await conversation(id).indexedHistory()
        return (Array(all.dropFirst(offset).prefix(limit)), all.count)
    }
    public func archivePage(before: Int64) async throws -> [AssistantConversation] {
        try await records?.list(before: before) ?? []
    }
    public func snapshot() async throws -> AssistantArchive {
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
    public func readCurrent() async throws -> AssistantReadSnapshot {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        return AssistantReadSnapshot(current: value.current, token: readToken)
    }

    /// Admits user text before a model request exists, under one current-conversation write fence.
    public func admitUserInput(id: String, user: String, model: String) async throws -> AssistantRecord {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        guard !value.current.turns.contains(where: { $0.id == id }) else {
            throw AssistantHistoryError.invalidRecord
        }
        return try await beginLocked(
            id: id, user: user, request: [], model: model,
            maximumOutputTokens: nil, temperature: 0.7, awaitingModel: true)
    }

    /// Persists the caller's exact request, rejecting intervening mutations.
    public func begin(
        id: String, user: String, request: [ModelMessage], expecting token: AssistantReadToken,
        model: String, maximumOutputTokens: Int? = nil, temperature: Double = 0.7, awaitingModel: Bool = false
    ) async throws -> AssistantRecord {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        guard token == readToken else { throw AssistantHistoryError.conflict }
        return try await beginLocked(
            id: id, user: user, request: request, model: model,
            maximumOutputTokens: maximumOutputTokens, temperature: temperature, awaitingModel: awaitingModel)
    }

    private func beginLocked(
        id: String, user: String, request: [ModelMessage], model: String,
        maximumOutputTokens: Int?, temperature: Double, awaitingModel: Bool
    ) async throws -> AssistantRecord {
        guard user.utf8.count <= 16_384, model.utf8.count <= 512,
            request.count <= 514,
            request.allSatisfy({ $0.content.utf8.count <= ($0.role == .system ? 65536 : 262144) }),
            temperature.isFinite, maximumOutputTokens.map({ $0 > 0 }) ?? true
        else { throw AssistantHistoryError.invalidRecord }

        if let index = value.current.turns.firstIndex(where: { $0.id == id }),
            value.current.turns[index].awaitingModel
        {
            guard value.current.turns[index].user == user, value.current.turns[index].state == .generating else {
                throw AssistantHistoryError.invalidRecord
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
            throw AssistantHistoryError.invalidRecord
        }
        var record = AssistantRecord(
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
            throw AssistantHistoryError.missingTurn
        }
        return accepted
    }

    private func updateTurn(
        _ id: String, required: Bool = true, change: (inout AssistantRecord) throws -> Bool
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
                    throw AssistantHistoryError.missingTurn
                }
                guard try change(&conversation.turns[index]) else { return }
                try await records.update(conversation)
                return
            } else {
                if required { throw AssistantHistoryError.missingTurn }
                return
            }
            do {
                dirtyInputs.insert(id)
                try await commit(next)
                return
            } catch AssistantHistoryError.conflict where contextLoad != nil && attempt < 3 {
                continue
            }
        }
    }

    public func beginModelRequest(_ request: AssistantModelRequest, for id: String, awaitingDispatch: Bool = false)
        async throws
    {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        guard request.input.utf8.count <= 65_536,
            let index = value.current.turns.firstIndex(where: { $0.id == id }),
            value.current.contentBytes + request.requestJSON.utf8.count
                + (request.decisionMetadata?.catalogJSON.utf8.count ?? 0) < Self.maximumBytes - 2 * 1024 * 1024,
            value.revision < UInt64.max
        else { throw AssistantHistoryError.invalidRecord }
        var next = value
        var requests = next.current.turns[index].modelRequests ?? []
        guard next.current.turns[index].state == .generating,
            !requests.contains(where: { $0.id == request.id || $0.state == .generating })
        else { throw AssistantHistoryError.invalidRecord }
        var admitted = request
        admitted.historyOrder = value.revision + 1
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
        else { throw AssistantHistoryError.missingTurn }
        guard value.current.turns[input].modelRequests?[request].awaitingDispatch == true else { return }
        try Task.checkCancellation()
        guard value.current.turns[input].state == .generating,
            value.current.turns[input].modelRequests?[request].state == .generating
        else { throw AssistantHistoryError.invalidRecord }
        if let task = value.current.turns[input].modelRequests?[request].historyTaskID,
            value.current.taskCompressions.contains(where: { $0.taskID == task && $0.closedAtAction == true })
        {
            throw RecordStorageError.conflict
        }
        var next = value
        next.current.turns[input].modelRequests?[request].awaitingDispatch = false
        next.current.turns[input].modelRequests?[request].date = Date()
        dirtyInputs.insert(id)
        try await commit(next)
        try await checkpointLocked()
    }

    public func clearRequestLogs(requestID: String?) async throws {
        guard let records else { throw AssistantHistoryError.invalidRecord }
        try await records.clearRequestLogs(requestID: requestID)
    }

    public func recordModelTransport(_ update: ModelRequestLogUpdate, for id: String) async throws {
        if case .request = update { try await markModelRequestDispatched(id) }
        guard let records else { return }
        let snapshot = try await readCurrent()
        guard let request = snapshot.current.turns.first(where: { $0.id == id })?.modelRequests?.last else {
            throw AssistantHistoryError.missingTurn
        }
        try await records.writeRequestPayload(request.id, json: "", response: "", initial: false, update: update)
    }

    public func recordModelExchange(requestJSON: String?, response: String, for id: String, initial: Bool = false)
        async throws
    {
        if let records, let requestJSON {
            let snapshot = try await readCurrent()
            guard let request = snapshot.current.turns.first(where: { $0.id == id })?.modelRequests?.last else {
                throw AssistantHistoryError.missingTurn
            }
            if request.awaitingDispatch != true {
                try await records.writeRequestPayload(
                    request.id, json: requestJSON, response: response, initial: initial)
            }
        }
        let retainedRequest = records == nil ? requestJSON : nil
        let retainedResponse = records == nil ? response : nil
        try await updateTurn(id) { turn in
            guard let index = turn.modelRequests?.indices.last else { throw AssistantHistoryError.missingTurn }
            turn.modelRequests?[index].requestParametersJSON = retainedRequest
            turn.modelRequests?[index].responseEventsJSON = retainedResponse
            return true
        }
    }

    /// Exact provider evidence; the original record date remains an admission timestamp.
    public func recordModelTiming(startedAt: Date, firstTokenAt: Date?, latency: Double?, for id: String) async throws {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
            firstTokenAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
            latency.map({ $0.isFinite && $0 >= 0 }) ?? true,
            (firstTokenAt == nil) == (latency == nil)
        else { throw AssistantHistoryError.invalidRecord }
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
            else { throw AssistantHistoryError.invalidRecord }
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
            throw AssistantHistoryError.capacityExceeded
        }
        try await updateTurn(id) {
            $0.toolDefinitions = definitions
            $0.toolCalls = []
            return true
        }
    }

    public func recordToolCall(_ call: ModelToolCall, for id: String) async throws {
        guard call.providerID.utf8.count <= 512, call.name.utf8.count <= 64
        else { throw AssistantHistoryError.invalidRecord }
        try await updateTurn(id) { turn in
            var calls = turn.toolCalls ?? []
            guard !calls.contains(where: { $0.id == call.id }) else {
                throw AssistantHistoryError.capacityExceeded
            }
            calls.append(call)
            turn.toolCalls = calls
            if let index = turn.modelRequests?.indices.last {
                turn.modelRequests?[index].toolCalls.append(call)
            }
            return true
        }
    }

    public func recordGenerationRound(_ round: ModelGenerationRound, for id: String) async throws {
        try await updateTurn(id, required: true) { turn in
            var rounds = turn.generationRounds ?? []
            guard !rounds.contains(where: { $0.id == round.id }) else {
                throw AssistantHistoryError.invalidRecord
            }
            rounds.append(round)
            turn.generationRounds = rounds
            return true
        }
    }

    public func recordToolOutcome(
        _ callID: String, for id: String, state: ModelToolCall.State,
        output: String? = nil, error: String? = nil, failureDiagnostic: ModelFailureDiagnostic? = nil
    ) async throws {
        guard state != .received else {
            throw AssistantHistoryError.invalidRecord
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
            throw AssistantHistoryError.invalidRecord
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
        else { throw AssistantHistoryError.missingTurn }
        var next = value
        var turn = next.current.turns[index]
        let directProducer = turn.modelRequests?.isEmpty ?? true
        // Direct text producers start their message on its first content event. Managed models
        // use beginModelRequest before invoking the provider, so their deltas perform no writes.
        if turn.modelRequests?.isEmpty ?? true {
            var request = AssistantModelRequest(
                id: UUID().uuidString, input: turn.user,
                requestJSON: String(decoding: try JSONEncoder().encode(turn.request), as: UTF8.self))
            request.historyOrder = value.revision + 1
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

    public func recordCoordination(_ evidence: AssistantInputCoordination, for id: String) async throws {
        try await updateTurn(id) {
            $0.coordination = evidence
            return true
        }
        try await checkpoint(inputID: id)
    }

    public func finish(
        _ id: String, state: AssistantRecord.State, reason: String? = nil, error: String? = nil,
        failureDiagnostic: ModelFailureDiagnostic? = nil
    ) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        guard let index = value.current.turns.firstIndex(where: { $0.id == id }), state != .generating else {
            throw AssistantHistoryError.missingTurn
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
            var request = AssistantModelRequest(
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
    public func startNew() async throws -> AssistantConversation? {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await synchronizeCurrentLocked()
        guard !value.current.turns.contains(where: { $0.state == .generating }) else {
            throw AssistantHistoryError.busy
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
            if let title, title.isEmpty || title.count > 80 { throw AssistantHistoryError.invalidRecord }
            try await records.setTitle(title, error: error.map { String($0.prefix(4096)) }, for: id)
            return
        }
        guard let index = value.past.firstIndex(where: { $0.id == id }) else {
            throw AssistantHistoryError.invalidRecord
        }
        if let title {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 80 else {
                throw AssistantHistoryError.invalidRecord
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

extension AssistantConversation {
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
            throw AssistantHistoryError.invalidRecord
        }
        let requests = turns.flatMap { turn in
            (turn.modelRequests ?? []).map { (AssistantHistoryReference(inputID: turn.id, requestID: $0.id), $0) }
        }.sorted { $0.1.historyOrder < $1.1.historyOrder }
        guard Set(requests.map { $0.0.requestID }).count == requests.count,
            Set(requests.map { $0.1.historyOrder }).count == requests.count,
            requests.allSatisfy({ $0.1.historyOrder > 0 })
        else {
            throw AssistantHistoryError.invalidRecord
        }
        for compression in taskCompressions {
            let owned = requests.filter {
                $0.1.historyTaskID == compression.taskID
                    && (compression.closedAtAction != true || $0.1.awaitingDispatch != true)
            }
            guard compression.status != .generating, !compression.sources.isEmpty,
                compression.sources.count <= 8192,
                compression.goal.utf8.count <= 4096,
                (compression.reportedSummary?.utf8.count ?? 0) <= 4096,
                (compression.failure?.utf8.count ?? 0) <= 16384,
                isWindow
                    ? Set(owned.map({ $0.0 })).isSubset(of: Set(compression.sources))
                    : owned.map({ $0.0 }) == compression.sources,
                compression.closedAtAction == true || owned.allSatisfy({ $0.1.state != .generating })
            else { throw AssistantHistoryError.invalidRecord }
        }
    }

    /// Replace only indexed sources, at the first source; intervening unrelated requests survive.
    public func indexedHistory() throws -> [AssistantHistoryItem] {
        try validateCompressions()
        let compressions = Dictionary(uniqueKeysWithValues: taskCompressions.map { ($0.taskID, $0) })
        var emitted: Set<String> = []
        let requests = turns.flatMap { turn in (turn.modelRequests ?? []).map { (turn, $0) } }
            .sorted { $0.1.historyOrder < $1.1.historyOrder }
        return requests.compactMap { turn, request -> AssistantHistoryItem? in
            if let task = request.historyTaskID, let compression = compressions[task] {
                return emitted.insert(task).inserted ? .task(compression) : nil
            }
            return .request(input: turn, request: request)
        }
    }
}

extension AssistantArchive {
    public func validate() throws {
        guard version == 4, revision < UInt64.max,
            Set(([current] + past).map(\.id)).count == past.count + 1
        else { throw AssistantHistoryError.invalidRecord }
        for conversation in [current] + past { try conversation.validateCompressions() }
    }

    public mutating func assignHistoryTask(_ taskID: String, inputID: String, requestID: String) throws {
        guard let turn = current.turns.firstIndex(where: { $0.id == inputID }),
            let request = current.turns[turn].modelRequests?.firstIndex(where: { $0.id == requestID })
        else { throw AssistantHistoryError.invalidRecord }
        // A round already owned by an earlier scope remains there; the next round uses the new task.
        guard current.turns[turn].modelRequests?[request].historyTaskID == nil else { return }
        current.turns[turn].modelRequests?[request].historyTaskID = taskID
        guard revision < UInt64.max else { throw AssistantHistoryError.capacityExceeded }
        revision += 1
    }
}
