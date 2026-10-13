import Foundation
import Storage

public enum ConversationHistoryError: Error, Equatable, Sendable {
    case busy, capacityExceeded, invalidRecord, missingTurn, emptyConversation, conflict
}

public struct ConversationMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ConversationTokenUsage: Codable, Sendable, Equatable {
    public let input: Int
    public let generated: Int
    public let total: Int
    public init(input: Int, generated: Int, total: Int) {
        self.input = input
        self.generated = generated
        self.total = total
    }
}

public struct ConversationToolCall: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case received, completed, failed, cancelled }
    public let id: UUID
    public let providerID: String
    public let name: String
    public let argumentsJSON: String
    public var state: State = .received
    public var output: String?
    public var error: String?
    public init(id: UUID, providerID: String, name: String, argumentsJSON: String) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ConversationGenerationRound: Codable, Sendable, Identifiable {
    public let id: UUID
    public let resultsJSON: String
    public init(id: UUID, resultsJSON: String) {
        self.id = id
        self.resultsJSON = resultsJSON
    }
}

/// Exact per-request Skill and task evidence.
public struct ConversationDecisionMetadata: Codable, Sendable {
    public let taskID: UUID?
    public let mode: String
    public let skills: [String: Int]
    public var catalogJSON: String
    public let taskGoal: String?
    public let execution: String?
    public init(
        taskID: UUID?, mode: String, skills: [String: Int], catalogJSON: String, taskGoal: String? = nil,
        execution: String? = nil
    ) {
        self.taskGoal = taskGoal
        self.execution = execution
        self.taskID = taskID
        self.mode = mode
        self.skills = skills
        self.catalogJSON = catalogJSON
    }
}

/// One model invocation, nested under the input that owns its execution lifecycle.
public struct ConversationModelRequest: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let input: String
    public var requestJSON: String
    public var historyOrder: UInt64 = 0
    public var historyTaskID: UUID?
    public var decisionMetadata: ConversationDecisionMetadata?
    public var modelRequestStartedAt: Date?
    public var firstTokenLatency: Double?
    public var firstTokenAt: Date?
    public var response: String = ""
    public var toolCalls: [ConversationToolCall] = []
    public var tokenUsage: ConversationTokenUsage?
    public var state: ConversationRecord.State = .generating
    public var finishReason: String?
    public var error: String?
    public init(
        id: UUID, input: String, requestJSON: String, decisionMetadata: ConversationDecisionMetadata? = nil,
        historyTaskID: UUID? = nil
    ) {
        self.historyTaskID = historyTaskID
        self.decisionMetadata = decisionMetadata
        self.id = id
        date = Date()
        self.input = input
        self.requestJSON = requestJSON
    }
}

public struct ConversationRecord: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case generating, completed, failed, cancelled, interrupted }
    public let id: UUID
    public let date: Date
    public let user: String
    public var request: [ConversationMessage]
    public var awaitingModel: Bool = false
    public var model: String
    public let maximumOutputTokens: Int?
    public let temperature: Double
    public var modelRequests: [ConversationModelRequest]?
    public var generationRounds: [ConversationGenerationRound]?
    public var toolDefinitions: [String]?
    public var toolCalls: [ConversationToolCall]?
    public var tokenUsage: ConversationTokenUsage?
    public var response: String = ""
    public var state: State = .generating
    public var finishReason: String?
    public var error: String?
    public var executionError: String?
    public var raw: String { response }
}

/// Stable raw-history address, independent of array positions and archive location.
public struct ConversationHistoryReference: Codable, Sendable, Equatable, Hashable {
    public let inputID: UUID
    public let requestID: UUID
    public init(inputID: UUID, requestID: UUID) {
        self.inputID = inputID
        self.requestID = requestID
    }
}

/// A separately persisted terminal record. Summary is model-reported; status/failure are host facts.
public struct ConversationTaskCompression: Codable, Sendable, Identifiable {
    public var id: UUID { taskID }
    public let taskID: UUID
    public let goal: String
    public let status: ConversationRecord.State
    public let reportedSummary: String?
    public let failure: String?
    public let completedAt: Date
    public let sources: [ConversationHistoryReference]
    public init(
        taskID: UUID, goal: String, status: ConversationRecord.State, reportedSummary: String?, failure: String?,
        completedAt: Date, sources: [ConversationHistoryReference]
    ) {
        self.taskID = taskID
        self.goal = goal
        self.status = status
        self.reportedSummary = reportedSummary
        self.failure = failure
        self.completedAt = completedAt
        self.sources = sources
    }
}

/// Structural read projection; callers own prompt selection and rendering.
public enum ConversationHistoryItem: Sendable {
    case request(input: ConversationRecord, request: ConversationModelRequest)
    case task(ConversationTaskCompression)
}

public struct StoredConversation: Codable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public var archivedAt: Date?
    public var summaryTitle: String?
    public var titleError: String?
    public var turnCount: Int?
    public var latestUser: String?
    public var inputIDs: [UUID]?
    public var turns: [ConversationRecord] = []
    public var taskCompressions: [ConversationTaskCompression] = []
    public init() {
        id = UUID()
        createdAt = Date()
    }
}

public struct ConversationArchive: Codable, Sendable {
    public let version: Int
    public var revision: UInt64 = 0
    public var current: StoredConversation
    public var past: [StoredConversation]
    public init() {
        version = 3
        current = StoredConversation()
        past = []
    }
}

/// Process-local read fence; tokens cannot be constructed outside StorageChat.
public struct ConversationReadToken: Sendable, Equatable {
    fileprivate let value: UUID
}

public struct ConversationReadSnapshot: Sendable {
    public let current: StoredConversation
    public let token: ConversationReadToken
}

/// One current in-memory conversation; optional per-conversation files supply checkpoints.
/// Writes are serialized across document awaits; at most 16 callers may wait, overflow fails busy.
public actor ConversationHistoryStore {
    public static let maximumBytes = 32 * 1024 * 1024
    public private(set) var lastCheckpointError: String?
    public private(set) var contextIdentity: UUID?
    private let files: ConversationFileStore?
    private let capture: (@Sendable () async throws -> ConversationFileSnapshot)?
    private let canArchive: (@Sendable () async throws -> Void)?
    private let restore: (@Sendable (ConversationArchive, Data?) async throws -> Void)?
    private var value = ConversationArchive()
    private var readToken = ConversationReadToken(value: UUID())
    private var savedID: UUID?
    private var savedRevision: UInt64?
    private var savedRecovery: Data?
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
    public init(files: ConversationFileStore? = nil) {
        self.files = files
        capture = nil
        canArchive = nil
        restore = nil
        contextIdentity = nil
        contextLoad = nil
        contextCommit = nil
    }
    /// Transactional projection over the Agent-owned authoritative context; no second writer.
    public init(
        contextIdentity: UUID? = nil, files: ConversationFileStore? = nil,
        capture: (@Sendable () async throws -> ConversationFileSnapshot)? = nil,
        canArchive: (@Sendable () async throws -> Void)? = nil,
        restore: (@Sendable (ConversationArchive, Data?) async throws -> Void)? = nil,
        contextLoad: @escaping @Sendable () async throws -> ConversationArchive,
        contextCommit: @escaping @Sendable (ConversationArchive) async throws -> Void
    ) {
        self.files = files
        self.capture = capture
        self.canArchive = canArchive
        self.restore = restore
        self.contextIdentity = contextIdentity
        self.contextLoad = contextLoad
        self.contextCommit = contextCommit
    }

    /// The host attaches the authoritative context without importing another journal.
    public func attachContext(
        identity: UUID,
        load: @escaping @Sendable () async throws -> ConversationArchive,
        commit: @escaping @Sendable (ConversationArchive) async throws -> Void
    ) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        guard contextIdentity == nil || contextIdentity == identity else { throw ConversationHistoryError.busy }
        let authoritative = try await load()
        guard authoritative.version == 3 else { throw DocumentStorageError.unsupportedVersion }
        contextIdentity = identity
        contextLoad = load
        contextCommit = commit
        value = authoritative
        loaded = true
        readToken = ConversationReadToken(value: UUID())
    }
    private func load() async throws {
        if !loaded, let files {
            if let saved = try await files.loadCurrent() {
                guard saved.version == 3 else { throw DocumentStorageError.unsupportedVersion }
                savedID = saved.conversation.id
                savedRevision = saved.revision
                savedRecovery = saved.recovery
                value.current = saved.conversation
                value.revision = saved.revision
                var recovered = false
                for index in value.current.turns.indices where value.current.turns[index].state == .generating {
                    recovered = true
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
            guard latest.version == 3 else { throw DocumentStorageError.unsupportedVersion }
            if latest.revision != value.revision { readToken = ConversationReadToken(value: UUID()) }
            value = latest
        }
        loaded = true
    }
    private func commit(_ candidate: ConversationArchive) async throws {
        var next = candidate
        guard value.revision < UInt64.max else { throw ConversationHistoryError.capacityExceeded }
        next.revision = value.revision + 1
        if let contextCommit { try await contextCommit(next) }
        if let contextLoad { value = try await contextLoad() } else { value = next }
        readToken = ConversationReadToken(value: UUID())
    }
    private func checkpointLocked() async throws {
        guard let files else { return }
        do {
            try value.validate()
            let snapshot = try await capture?() ?? .init(conversation: value.current, revision: value.revision)
            guard snapshot.conversation.id == value.current.id else { throw ConversationHistoryError.conflict }
            if snapshot.conversation.id == savedID && snapshot.revision == savedRevision
                && snapshot.recovery == savedRecovery, try await files.currentExists()
            {
                return
            }
            try await files.saveCurrent(snapshot)
            savedID = snapshot.conversation.id
            savedRevision = snapshot.revision
            savedRecovery = snapshot.recovery
            lastCheckpointError = nil
        } catch {
            lastCheckpointError = String(describing: error)
            throw error
        }
    }
    public func checkpoint() async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        try await checkpointLocked()
    }
    public func listConversations() async throws -> [StoredConversation] {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        return [value.current] + (try await files?.list() ?? value.past)
    }
    public func conversation(_ id: UUID) async throws -> StoredConversation {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if value.current.id == id { return value.current }
        if let files { return try await files.read(id) }
        guard let saved = value.past.first(where: { $0.id == id }) else { throw ConversationHistoryError.missingTurn }
        return saved
    }
    public func snapshot() async throws -> ConversationArchive {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        var result = value
        if let files { result.past = try await files.list() }
        return result
    }

    /// Reads records and a fence atomically, without selecting model context.
    public func readCurrent() async throws -> ConversationReadSnapshot {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        return ConversationReadSnapshot(current: value.current, token: readToken)
    }

    /// Persists the caller's exact request, rejecting intervening mutations.
    public func begin(
        id: UUID, user: String, request: [ConversationMessage], expecting token: ConversationReadToken,
        model: String, maximumOutputTokens: Int? = nil, temperature: Double = 0.7, awaitingModel: Bool = false
    ) async throws -> ConversationRecord {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        guard token == readToken else { throw ConversationHistoryError.conflict }

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
            try await commit(next)
            return value.current.turns[index]
        }
        guard value.current.turns.count < 256 else { throw ConversationHistoryError.capacityExceeded }
        guard !value.current.turns.contains(where: { $0.id == id }) else {
            throw ConversationHistoryError.invalidRecord
        }
        var record = ConversationRecord(
            id: id, date: Date(), user: user, request: request, model: model,
            maximumOutputTokens: maximumOutputTokens, temperature: temperature)
        record.awaitingModel = awaitingModel
        var next = value
        next.current.turns.append(record)
        try await commit(next)
        try await checkpointLocked()
        return record
    }

    private func updateTurn(
        _ id: UUID, required: Bool = true, change: (inout ConversationRecord) throws -> Bool
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
            } else if let files,
                let archive = try await files.list().first(where: { $0.inputIDs?.contains(id) == true })
            {
                var conversation = try await files.read(archive.id)
                guard let index = conversation.turns.firstIndex(where: { $0.id == id }) else {
                    throw ConversationHistoryError.missingTurn
                }
                guard try change(&conversation.turns[index]) else { return }
                try await files.update(conversation)
                return
            } else {
                if required { throw ConversationHistoryError.missingTurn }
                return
            }
            do {
                try await commit(next)
                return
            } catch ConversationHistoryError.conflict where contextLoad != nil && attempt < 3 {
                continue
            }
        }
    }

    public func beginModelRequest(_ request: ConversationModelRequest, for id: UUID) async throws {
        guard request.input.utf8.count <= 65_536, request.requestJSON.utf8.count <= 524_288 else {
            throw ConversationHistoryError.invalidRecord
        }
        try await updateTurn(id) { turn in
            guard
                value.current.contentBytes + request.requestJSON.utf8.count
                    + (request.decisionMetadata?.catalogJSON.utf8.count ?? 0) < Self.maximumBytes - 2 * 1024 * 1024
            else {
                throw ConversationHistoryError.capacityExceeded
            }
            var requests = turn.modelRequests ?? []
            guard turn.state == .generating,
                !requests.contains(where: { $0.id == request.id || $0.state == .generating })
            else { throw ConversationHistoryError.invalidRecord }
            var admitted = request
            guard value.revision < UInt64.max else { throw ConversationHistoryError.capacityExceeded }
            admitted.historyOrder = value.revision + 1
            requests.append(admitted)
            turn.modelRequests = requests
            return true
        }
    }

    /// Exact provider evidence; the original record date remains an admission timestamp.
    public func recordModelTiming(startedAt: Date, firstTokenAt: Date?, latency: Double?, for id: UUID) async throws {
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

    public func finishModelRequest(_ id: UUID, reason: String?, error: String? = nil) async throws {
        try await updateTurn(id) { turn in
            guard let index = turn.modelRequests?.indices.last,
                turn.modelRequests?[index].state == .generating
            else { throw ConversationHistoryError.invalidRecord }
            turn.modelRequests?[index].state = error == nil ? .completed : .failed
            turn.modelRequests?[index].finishReason = reason
            turn.modelRequests?[index].error = error.map { String($0.prefix(4096)) }
            return true
        }
    }

    public func recordToolDefinitions(_ definitions: [String], for id: UUID) async throws {
        guard definitions.count <= 128, definitions.reduce(0, { $0 + $1.utf8.count }) <= 65536 else {
            throw ConversationHistoryError.capacityExceeded
        }
        try await updateTurn(id) {
            $0.toolDefinitions = definitions
            $0.toolCalls = []
            return true
        }
    }

    public func recordToolCall(_ call: ConversationToolCall, for id: UUID) async throws {
        guard call.providerID.utf8.count <= 512, call.name.utf8.count <= 64,
            call.argumentsJSON.utf8.count <= 4096
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

    public func recordGenerationRound(_ round: ConversationGenerationRound, for id: UUID) async throws {
        guard round.resultsJSON.utf8.count <= 262_144 else { throw ConversationHistoryError.invalidRecord }
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
        _ callID: UUID, for id: UUID, state: ConversationToolCall.State,
        output: String? = nil, error: String? = nil
    ) async throws {
        guard state != .received, (output?.utf8.count ?? 0) <= 65536 else {
            throw ConversationHistoryError.invalidRecord
        }
        try await updateTurn(id, required: false) { turn in
            // Fixed internal UI Tools are deliberately absent from model-call history.
            guard let index = turn.toolCalls?.firstIndex(where: { $0.id == callID }) else { return false }
            turn.toolCalls?[index].state = state
            turn.toolCalls?[index].output = output
            turn.toolCalls?[index].error = error.map { String($0.prefix(4096)) }
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

    public func recordTokenUsage(_ usage: ConversationTokenUsage, for id: UUID) async throws {
        guard usage.input >= 0, usage.generated >= 0, usage.total >= 0 else {
            throw ConversationHistoryError.invalidRecord
        }
        try await updateTurn(id) {
            $0.tokenUsage = usage
            if let index = $0.modelRequests?.indices.last { $0.modelRequests?[index].tokenUsage = usage }
            return true
        }
    }

    public func append(_ delta: String, to id: UUID) async throws {
        try await updateTurn(id) { turn in
            guard turn.state == .generating else { throw ConversationHistoryError.missingTurn }
            guard turn.raw.utf8.count + delta.utf8.count <= 262144 else {
                throw ConversationHistoryError.capacityExceeded
            }
            turn.response += delta
            if let request = turn.modelRequests?.indices.last { turn.modelRequests?[request].response += delta }
            return true
        }
    }

    public func finish(
        _ id: UUID, state: ConversationRecord.State, reason: String? = nil, error: String? = nil
    ) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        guard let index = value.current.turns.firstIndex(where: { $0.id == id }), state != .generating else {
            throw ConversationHistoryError.missingTurn
        }
        var next = value
        next.current.turns[index].state = state
        next.current.turns[index].finishReason = reason
        next.current.turns[index].error = error.map { String($0.prefix(4096)) }
        if let request = next.current.turns[index].modelRequests?.indices.last,
            next.current.turns[index].modelRequests?[request].state == .generating
        {
            next.current.turns[index].modelRequests?[request].state = state
            next.current.turns[index].modelRequests?[request].finishReason = reason
            let failure = next.current.turns[index].error
            next.current.turns[index].modelRequests?[request].error = failure
        }
        do {
            try await commit(next)
            try await checkpointLocked()
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
        guard !value.current.turns.contains(where: { $0.state == .generating }) else {
            throw ConversationHistoryError.busy
        }
        guard !value.current.turns.isEmpty else { return nil }
        guard value.past.count < 64 else { throw ConversationHistoryError.capacityExceeded }
        try await canArchive?()
        var next = value
        next.current.archivedAt = Date()
        let archived = next.current
        next.current = StoredConversation()
        if let files {
            var snapshot = try await capture?() ?? .init(conversation: archived, revision: value.revision)
            snapshot.conversation = archived
            try await files.rotate(snapshot, next: next.current)
        } else {
            next.past.insert(archived, at: 0)
        }
        try await commit(next)
        return archived
    }

    public func setTitle(_ title: String?, error: String? = nil, for id: UUID) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if let files {
            if let title, title.isEmpty || title.count > 80 { throw ConversationHistoryError.invalidRecord }
            try await files.setTitle(title, error: error.map { String($0.prefix(4096)) }, for: id)
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

    public func recordExecutionFailure(_ error: String, for id: UUID) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        guard let index = value.current.turns.firstIndex(where: { $0.id == id }) else { return }
        var next = value
        next.current.turns[index].executionError = String(error.prefix(4096))
        try await commit(next)
    }

    public func deleteArchived(_ id: UUID) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        if let files {
            try await files.delete(id)
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
        guard taskCompressions.count <= 256, Set(taskCompressions.map(\.taskID)).count == taskCompressions.count else {
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
                owned.map({ $0.0 }) == compression.sources,
                owned.allSatisfy({ $0.1.state != .generating })
            else { throw ConversationHistoryError.invalidRecord }
        }
    }

    /// Replace only indexed sources, at the first source; intervening unrelated requests survive.
    public func indexedHistory() throws -> [ConversationHistoryItem] {
        try validateCompressions()
        let compressions = Dictionary(uniqueKeysWithValues: taskCompressions.map { ($0.taskID, $0) })
        var emitted: Set<UUID> = []
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
        guard version == 3, revision < UInt64.max, current.turns.count <= 256, past.count <= 64,
            past.allSatisfy({ $0.turns.count <= 256 }),
            Set(([current] + past).map(\.id)).count == past.count + 1
        else { throw ConversationHistoryError.invalidRecord }
        for conversation in [current] + past { try conversation.validateCompressions() }
    }

    public mutating func assignHistoryTask(_ taskID: UUID, inputID: UUID, requestID: UUID) throws {
        guard let turn = current.turns.firstIndex(where: { $0.id == inputID }),
            let request = current.turns[turn].modelRequests?.firstIndex(where: { $0.id == requestID }),
            current.turns[turn].modelRequests?[request].historyTaskID == nil
        else { throw ConversationHistoryError.invalidRecord }
        current.turns[turn].modelRequests?[request].historyTaskID = taskID
        guard revision < UInt64.max else { throw ConversationHistoryError.capacityExceeded }
        revision += 1
    }
}
