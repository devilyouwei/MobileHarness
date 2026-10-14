import Foundation
import Observation

@MainActor @Observable
public final class ConversationHistoryState {
    public let title: String
    public var selectedConversation: HistoryConversation?
    public var archive: HistorySnapshot?
    public var status: String?
    public var isBusy = false
    public init(title: String = "Assistant 聊天记录") {
        self.title = title
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
    func loadConversation(_ id: UUID) async throws -> HistoryConversation
    func startNew()
    func summarize(_ id: UUID)
    func delete(_ id: UUID)
    func cancel()
    func preview(_ turn: HistoryTurn) -> String
    func imageData(_ id: UUID, for turnID: UUID) async throws -> Data?
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
    public let id: UUID
    public let mimeType: String
    public let byteCount: Int
    public init(id: UUID, mimeType: String, byteCount: Int) {
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
    public let taskID: UUID?
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
    public var historyOrder: UInt64 = 0
    public let id: UUID
    public let date: Date
    public let input: String
    public let requestJSON: String
    public var historyTaskID: UUID? = nil
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
    public let id: UUID
    public let providerID: String
    public let name: String
    public let argumentsJSON: String
    public var state: State = .received
    public let output: String?
    public let error: String?
    public init(id: UUID, providerID: String, name: String, argumentsJSON: String) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.argumentsJSON = argumentsJSON
        output = nil
        error = nil
    }
}

public struct HistoryTurn: Codable, Sendable, Identifiable {
    public var historyOrder: UInt64? = nil
    public enum State: String, Codable, Sendable { case generating, completed, failed, cancelled, interrupted }
    public let id: UUID
    public let date: Date
    public let user: String
    public let request: [HistoryMessage]
    public let model: String
    public let maximumOutputTokens: Int?
    public let temperature: Double
    public let modelRequests: [HistoryModelRequest]?
    public let firstTokenAt: Date?
    public let requestJSON: String?
    public let ownerInputID: UUID?
    public let isReACT: Bool?
    public let toolDefinitions: [String]?
    public let toolCalls: [HistoryToolCall]?
    public let tokenUsage: HistoryTokenUsage?
    public var response: String = ""
    public var state: State = .generating
    public let finishReason: String?
    public let error: String?
    public let executionError: String?
    public var historyTaskID: UUID? = nil
    public var decisionMetadata: HistoryDecisionMetadata? = nil
    public var modelRequestStartedAt: Date?
    public var firstTokenLatency: Double?
    public var raw: String { response }
}

public struct HistoryConversation: Codable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let archivedAt: Date?
    public let summaryTitle: String?
    public let titleError: String?
    public var turnCount: Int?
    public var latestUser: String?
    public var turns: [HistoryTurn] = []
    public var taskCompressions: [HistoryTaskCompression] = []
    public init() {
        id = UUID()
        createdAt = Date()
        archivedAt = nil
        summaryTitle = nil
        titleError = nil
    }
}

public struct HistorySnapshot: Codable, Sendable {
    public let version: Int
    public var current: HistoryConversation
    public var past: [HistoryConversation]
    public init() {
        version = 3
        current = HistoryConversation()
        past = []
    }
}

public struct HistorySourceReference: Codable, Sendable, Equatable {
    public let inputID: UUID
    public let requestID: UUID
}

public struct HistoryTaskCompression: Codable, Sendable, Identifiable {
    public var id: UUID { taskID }
    public let taskID: UUID
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
    public var id: UUID {
        switch self {
        case .request(let turn): turn.id
        case .task(let compression, _): compression.taskID
        }
    }
}

public enum HistoryDetailError: Error { case unavailable }
