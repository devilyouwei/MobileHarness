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

public struct ConversationRecord: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case generating, completed, failed, cancelled, interrupted }
    public let id: UUID
    public let date: Date
    public let user: String
    public let request: [ConversationMessage]
    public let model: String
    public let maximumOutputTokens: Int?
    public let temperature: Double
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
/// Writes are serialized by an admission flag across the document actor await; no write queue exists.
public actor ConversationHistoryStore {
    public static let maximumBytes = 32 * 1024 * 1024
    private let document: LocalDocumentStore<ConversationArchive>?
    private var value = ConversationArchive()
    private var revision: UUID?
    private var loaded = false
    private var writing = false

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
        guard !writing else { throw ConversationHistoryError.busy }
        writing = true
        defer { writing = false }
        try await load()
        return value
    }

    /// Persists input and the exact request before inference; prior context contains at most ten completed turns.
    public func begin(
        id: UUID, user: String, system: String, model: String,
        maximumOutputTokens: Int? = nil, temperature: Double = 0.7
    ) async throws -> ConversationRecord {
        guard !writing else { throw ConversationHistoryError.busy }
        writing = true
        defer { writing = false }
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

    public func append(_ delta: String, to id: UUID) async throws {
        guard !writing else { throw ConversationHistoryError.busy }
        writing = true
        defer { writing = false }
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
        guard !writing else { throw ConversationHistoryError.busy }
        writing = true
        defer { writing = false }
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
        guard !writing else { throw ConversationHistoryError.busy }
        writing = true
        defer { writing = false }
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
        guard !writing else { throw ConversationHistoryError.busy }
        writing = true
        defer { writing = false }
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
        guard !writing else { throw ConversationHistoryError.busy }
        writing = true
        defer { writing = false }
        try await load()
        guard let index = value.current.turns.firstIndex(where: { $0.id == id }) else { return }
        var next = value
        next.current.turns[index].executionError = String(error.prefix(4096))
        try await commit(next)
    }

    public func deleteArchived(_ id: UUID) async throws {
        guard !writing else { throw ConversationHistoryError.busy }
        writing = true
        defer { writing = false }
        try await load()
        var next = value
        next.past.removeAll { $0.id == id }
        try await commit(next)
    }
}
