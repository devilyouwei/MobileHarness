import Foundation
import Observation

@MainActor @Observable
public final class ConversationHistoryState {
    public let title: String
    public var selectedConversation: HistoryConversation?
    public var archive: HistorySnapshot?
    public var status: String?
    public var isBusy = false
    public var isRefreshing = false
    public var hasMoreArchives = false
    public var archivePaging = HistoryPageLoading<String>()
    public func present(_ snapshot: HistorySnapshot, status: String?) {
        archive = snapshot
        self.status = status
    }
    public init(title: String = "Assistant 聊天记录") {
        self.title = title
    }
}

/// Scoped to a page's identity: returning from a child does not request its first page again.
public struct HistoryInitialLoad: Sendable {
    private enum Phase: Sendable { case idle, loading, loaded }
    private var phase = Phase.idle
    public init() {}
    public mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .loading
        return true
    }
    public mutating func finish(succeeded: Bool) {
        if succeeded {
            phase = .loaded
        } else if phase == .loading {
            phase = .idle
        }
    }
}

/// One attempt per cursor unless the user explicitly retries; tickets fence late completions.
public struct HistoryPageLoading<Cursor: Hashable & Sendable>: Sendable {
    public private(set) var error: String?
    public private(set) var completionID: UUID?
    private var attemptedCursor: Cursor?
    private var active: UUID?
    public var isLoading: Bool { active != nil }
    public init() {}
    public mutating func begin(after cursor: Cursor, retry: Bool = false) -> UUID? {
        guard active == nil, retry || attemptedCursor != cursor else { return nil }
        let ticket = UUID()
        attemptedCursor = cursor
        active = ticket
        error = nil
        return ticket
    }
    public func accepts(_ ticket: UUID) -> Bool { active == ticket }
    public mutating func finish(_ ticket: UUID, error: String? = nil) {
        guard accepts(ticket) else { return }
        active = nil
        self.error = error.map { String($0.prefix(2048)) }
        completionID = UUID()
    }
    public mutating func cancel(_ ticket: UUID) {
        guard accepts(ticket) else { return }
        active = nil
        attemptedCursor = nil
        error = nil
        completionID = UUID()
    }
}

/// One request destination per history page; repeated taps cannot append destinations.
public struct HistoryRequestNavigation {
    public private(set) var turn: HistoryTurn?
    public var isPresented = false
    public init() {}
    public mutating func open(_ turn: HistoryTurn) {
        guard !isPresented else { return }
        self.turn = turn
        isPresented = true
    }
}

@MainActor
public protocol ConversationHistoryControlling: AnyObject {
    func load() async
    func loadConversation(_ id: String) async throws -> HistoryConversation
    func loadConversation(_ id: String, after: UInt64, taskID: String?) async throws -> HistoryConversation
    func loadMessage(_ turn: HistoryTurn) async throws -> HistoryTurn
    func loadMoreArchives(retry: Bool) async
    func startNew()
    func summarize(_ id: String)
    func delete(_ id: String)
    func cancel()
    func preview(_ turn: HistoryTurn) -> String
    func imageData(_ id: String, for turnID: String) async throws -> Data?
}

public struct HistoryMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let content: String
    public let toolCalls: [HistoryNativeToolCall]?
    public let toolCallID: String?
    public let imageReferences: [HistoryImageReference]?
    public init(role: Role, content: String, imageReferences: [HistoryImageReference] = []) {
        self.role = role
        self.content = content
        toolCalls = nil
        toolCallID = nil
        self.imageReferences = imageReferences.isEmpty ? nil : imageReferences
    }
}

public struct HistoryImageReference: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let mimeType: String
    public let byteCount: Int
    public init(id: String, mimeType: String, byteCount: Int) {
        self.id = id
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
    public var isValid: Bool {
        ["image/jpeg", "image/png"].contains(mimeType) && byteCount > 0 && byteCount <= 4 * 1024 * 1024
    }
}

public struct HistoryNativeToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
}

public struct HistoryDecisionMetadata: Codable, Sendable {
    public var taskGoal: String? = nil
    public var execution: String? = nil
    public let taskID: String?
    public let mode: String
    public let skills: [String: Int]
    public let catalogJSON: String
    public var summary: String {
        (execution == nil ? "默认对话" : (execution == "background" ? "后台任务" : "前台任务") + " · " + (taskGoal ?? ""))
            + " · Skills: "
            + skills.keys.sorted().map { "\($0)@\(skills[$0] ?? 0)" }.joined(separator: ", ")
    }
}

public struct HistoryModelRequest: Codable, Sendable, Identifiable {
    public var messageID: String? = nil
    public var isObservation: Bool? = nil
    public var historyOrder: UInt64 = 0
    public let id: String
    public let date: Date
    public let input: String
    public let requestJSON: String
    public var historyTaskID: String? = nil
    public var decisionMetadata: HistoryDecisionMetadata? = nil
    public let modelRequestStartedAt: Date?
    public let firstTokenLatency: Double?
    public let firstTokenAt: Date?
    public let response: String
    public let toolCalls: [HistoryToolCall]
    public let tokenUsage: HistoryTokenUsage?
    public let state: HistoryTurn.State
    public let finishReason: String?
    public let error: String?
}

public struct HistoryTokenUsage: Codable, Sendable, Equatable {
    public let input: Int
    public let generated: Int
    public let total: Int
    public init(input: Int, generated: Int, total: Int) {
        self.input = input
        self.generated = generated
        self.total = total
    }
}

public struct HistoryToolCall: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case received, completed, failed, cancelled }
    public let id: String
    public let providerID: String
    public let name: String
    public let argumentsJSON: String
    public var state: State = .received
    public let output: String?
    public let error: String?
    public init(id: String, providerID: String, name: String, argumentsJSON: String) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.argumentsJSON = argumentsJSON
        output = nil
        error = nil
    }
}

public struct HistoryTurn: Codable, Sendable, Identifiable {
    public var messageID: String? = nil
    public var historyOrder: UInt64? = nil
    public enum State: String, Codable, Sendable { case generating, completed, failed, cancelled, interrupted }
    public let id: String
    public let date: Date
    public let user: String
    public let request: [HistoryMessage]
    public let model: String
    public let maximumOutputTokens: Int?
    public let temperature: Double
    public let modelRequests: [HistoryModelRequest]?
    public let firstTokenAt: Date?
    public let requestJSON: String?
    public let ownerInputID: String?
    public let isReACT: Bool?
    public let toolDefinitions: [String]?
    public let toolCalls: [HistoryToolCall]?
    public let tokenUsage: HistoryTokenUsage?
    public var response: String = ""
    public var state: State = .generating
    public let finishReason: String?
    public let error: String?
    public let executionError: String?
    public var historyTaskID: String? = nil
    public var decisionMetadata: HistoryDecisionMetadata? = nil
    public var modelRequestStartedAt: Date?
    public var firstTokenLatency: Double?
    public var raw: String { response }
}

public struct HistoryConversation: Codable, Sendable, Identifiable {
    public var nextPosition: UInt64? = nil
    public let id: String
    public let createdAt: Date
    public let archivedAt: Date?
    public let summaryTitle: String?
    public let titleError: String?
    public var turnCount: Int?
    public var latestUser: String?
    public var turns: [HistoryTurn] = []
    public var taskCompressions: [HistoryTaskCompression] = []
    public init() {
        id = UUID().uuidString
        createdAt = Date()
        archivedAt = nil
        summaryTitle = nil
        titleError = nil
    }
    /// Append a SQL preview/source page without dropping the summaries needed to render Task cards.
    public mutating func appendPage(_ page: HistoryConversation) throws {
        guard page.id == id else { throw HistoryDetailError.unavailable }
        turns.append(contentsOf: page.turns)
        for compression in page.taskCompressions {
            if let index = taskCompressions.firstIndex(where: { $0.taskID == compression.taskID }) {
                taskCompressions[index] = compression
            } else {
                taskCompressions.append(compression)
            }
        }
        nextPosition = page.nextPosition
        turnCount = page.turnCount ?? turnCount
        latestUser = page.latestUser ?? latestUser
    }
}

public struct HistorySnapshot: Codable, Sendable {
    public let version: Int
    public var current: HistoryConversation
    public var past: [HistoryConversation]
    public init() {
        version = 4
        current = HistoryConversation()
        past = []
    }
}

public struct HistorySourceReference: Codable, Sendable, Hashable {
    public let inputID: String
    public let requestID: String
}

public struct HistoryTaskCompression: Codable, Sendable, Identifiable {
    public var id: String { taskID }
    public let taskID: String
    public let goal: String
    public let status: HistoryTurn.State
    public let reportedSummary: String?
    public let failure: String?
    public let completedAt: Date
    public let sources: [HistorySourceReference]
    public var text: String {
        [reportedSummary, failure.map { "失败：" + $0 }].compactMap { $0 }.joined(separator: "\n")
    }
}

public enum HistoryTimelineItem: Identifiable, Sendable {
    case request(HistoryTurn)
    case task(HistoryTaskCompression, sources: [HistoryTurn])
    public var id: String {
        switch self {
        case .request(let turn): turn.id
        case .task(let compression, _): compression.taskID
        }
    }
}

public enum HistoryDetailError: Error { case unavailable }
