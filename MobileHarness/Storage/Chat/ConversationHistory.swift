import Foundation
import Storage

public enum ConversationHistoryError: Error, Equatable, Sendable {
    case busy, capacityExceeded, invalidRecord, missingTurn, emptyConversation
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

public struct ConversationRecord: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case generating, completed, failed, cancelled, interrupted }
    public let id: UUID
    public let date: Date
    public let user: String
    public let request: [ConversationMessage]
    public let model: String
    public let maximumOutputTokens: Int?
    public let temperature: Double
    // Optional additions keep version-1 records readable without migration.
    public var toolDefinitions: [String]?
    public var toolCalls: [ConversationToolCall]?
    public var tokenUsage: ConversationTokenUsage?
    public var fragments: [String] = []
    public var state: State = .generating
    public var finishReason: String?
    public var error: String?
    public var executionError: String?
    public var raw: String { fragments.joined() }
}

public struct StoredConversation: Codable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public var archivedAt: Date?
    public var summaryTitle: String?
    public var titleError: String?
    public var turns: [ConversationRecord] = []
    public var title: String {
        if archivedAt != nil { return summaryTitle ?? "待生成标题" }
        return turns.last?.user ?? "新对话"
    }
    public init() {
        id = UUID()
        createdAt = Date()
    }
}

public struct ConversationArchive: Codable, Sendable {
    public let version: Int
    public var current: StoredConversation
    public var past: [StoredConversation]
    public init() {
        version = 1
        current = StoredConversation()
        past = []
    }
}

/// One process-wide journal. A nil document is an explicit in-memory mode for isolated tests.
/// Writes are serialized across document awaits; at most 16 callers may wait, overflow fails busy.
public actor ConversationHistoryStore {
    public static let maximumBytes = 32 * 1024 * 1024
    private let document: LocalDocumentStore<ConversationArchive>?
    private var value = ConversationArchive()
    private var revision: UUID?
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

    public init(document: LocalDocumentStore<ConversationArchive>? = nil) { self.document = document }

    private func load() async throws {
        guard !loaded else { return }
        if let saved = try await document?.load() {
            guard saved.value.version == 1 else { throw DocumentStorageError.unsupportedVersion }
            value = saved.value
            revision = saved.revision
            // An unfinished journal record after process restart is evidence of interruption.
            for index in value.current.turns.indices where value.current.turns[index].state == .generating {
                value.current.turns[index].state = .interrupted
                value.current.turns[index].error =
                    "App stopped before generation completed; retained output may be partial."
            }
        }
        loaded = true
    }

    private func commit(_ next: ConversationArchive, reserve: Int = 1024) async throws {
        guard try JSONEncoder().encode(next).count <= Self.maximumBytes - reserve else {
            throw ConversationHistoryError.capacityExceeded
        }
        if let document {
            let saved = try await document.save(next, expecting: revision)
            revision = saved.revision
        }
        value = next
    }

    public func snapshot() async throws -> ConversationArchive {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        return value
    }

    /// Persists input and the exact request before inference; prior context contains at most ten completed turns.
    public func begin(
        id: UUID, user: String, system: String, model: String,
        maximumOutputTokens: Int? = nil, temperature: Double = 0.7
    ) async throws -> ConversationRecord {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        guard !value.current.turns.contains(where: { $0.state == .generating }) else {
            throw ConversationHistoryError.busy
        }
        guard value.current.turns.count < 256 else { throw ConversationHistoryError.capacityExceeded }
        guard user.utf8.count <= 4096, system.utf8.count <= 32768, model.utf8.count <= 512,
            !value.current.turns.contains(where: { $0.id == id })
        else { throw ConversationHistoryError.invalidRecord }
        let history = value.current.turns.filter { $0.state == .completed }.suffix(10)
        var messages = [ConversationMessage(role: .system, content: system)]
        for turn in history {
            messages += [.init(role: .user, content: turn.user), .init(role: .assistant, content: turn.raw)]
        }
        messages.append(.init(role: .user, content: user))
        let record = ConversationRecord(
            id: id, date: Date(), user: user, request: messages, model: model,
            maximumOutputTokens: maximumOutputTokens, temperature: temperature)
        var next = value
        next.current.turns.append(record)
        try await commit(next, reserve: 32768)
        return record
    }

    private func updateTurn(
        _ id: UUID, required: Bool = true, change: (inout ConversationRecord) throws -> Bool
    ) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        var next = value
        if let index = next.current.turns.firstIndex(where: { $0.id == id }) {
            guard try change(&next.current.turns[index]) else { return }
        } else if let archive = next.past.firstIndex(where: { $0.turns.contains(where: { $0.id == id }) }),
            let index = next.past[archive].turns.firstIndex(where: { $0.id == id })
        {
            guard try change(&next.past[archive].turns[index]) else { return }
        } else {
            if required { throw ConversationHistoryError.missingTurn }
            return
        }
        try await commit(next, reserve: 32768)
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
            guard calls.count < 128, !calls.contains(where: { $0.id == call.id }) else {
                throw ConversationHistoryError.capacityExceeded
            }
            calls.append(call)
            turn.toolCalls = calls
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
            return true
        }
    }

    public func recordTokenUsage(_ usage: ConversationTokenUsage, for id: UUID) async throws {
        guard usage.input >= 0, usage.generated >= 0, usage.total >= 0 else {
            throw ConversationHistoryError.invalidRecord
        }
        try await updateTurn(id) {
            $0.tokenUsage = usage
            return true
        }
    }

    public func append(_ delta: String, to id: UUID) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
        guard let index = value.current.turns.firstIndex(where: { $0.id == id }),
            value.current.turns[index].state == .generating
        else { throw ConversationHistoryError.missingTurn }
        let turn = value.current.turns[index]
        guard turn.fragments.count < 8192, turn.raw.utf8.count + delta.utf8.count <= 262144 else {
            throw ConversationHistoryError.capacityExceeded
        }
        var next = value
        next.current.turns[index].fragments.append(delta)
        try await commit(next, reserve: 32768)
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
        do {
            try await commit(next)
        } catch {
            // The producer has ended even if disk protection/capacity prevented its terminal write.
            // Keep the raw prefix and make the unsaved terminal state explicit; a later write retries it.
            value.current.turns[index].state = .interrupted
            value.current.turns[index].error = "Terminal status could not be saved: \(error)"
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
        var next = value
        next.current.archivedAt = Date()
        let archived = next.current
        next.past.insert(archived, at: 0)
        next.current = StoredConversation()
        try await commit(next)
        return archived
    }

    public func setTitle(_ title: String?, error: String? = nil, for id: UUID) async throws {
        try await acquireWrite()
        defer { releaseWrite() }
        try await load()
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
        var next = value
        next.past.removeAll { $0.id == id }
        try await commit(next)
    }
}
