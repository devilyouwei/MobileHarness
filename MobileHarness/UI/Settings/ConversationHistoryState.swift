import Foundation
import Observation

@MainActor @Observable
public final class ConversationHistoryState {
    public let title: String
    public let allowsMutations: Bool
    public let groupsByTask: Bool
    public var archive: HistorySnapshot?
    public var tasks: [HistoryTask] = []
    public var status: String?
    public var isBusy = false
    public init(title: String = "历史记录", allowsMutations: Bool = true, groupsByTask: Bool = false) {
        self.title = title
        self.allowsMutations = allowsMutations
        self.groupsByTask = groupsByTask
    }
}

/// Immutable task projection; identity and membership are resolved by App from Agent context.
public struct HistoryTask: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let status: String
    public let createdAt: Date?
    public let turns: [HistoryTurn]
    public var execution: String?
    public var executor: String?
    public var resultText: String?
    public var parentTaskID: UUID?
    public var skills: [String] = []
    public init(
        id: UUID, title: String, status: String, createdAt: Date?, turns: [HistoryTurn]
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.turns = turns
    }
}

public struct HistoryAgentSnapshot: Sendable {
    public let archive: HistorySnapshot
    public let tasks: [HistoryTask]
    public init(archive: HistorySnapshot, tasks: [HistoryTask]) {
        self.archive = archive
        self.tasks = tasks
    }
}

@MainActor
public protocol ConversationHistoryControlling: AnyObject {
    var agents: [HistoryAgentDestination] { get }
    func load() async
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
    public let id: UUID
    public let date: Date
    public let input: String
    public let requestJSON: String
    public var decisionMetadata: HistoryDecisionMetadata? = nil
    public let modelRequestStartedAt: Date?
    public let firstTokenLatency: Double?
    public let firstTokenAt: Date?
    public let fragments: [String]
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
    public var fragments: [String] = []
    public var state: State = .generating
    public let finishReason: String?
    public let error: String?
    public let executionError: String?
    public var decisionMetadata: HistoryDecisionMetadata? = nil
    public var modelRequestStartedAt: Date?
    public var firstTokenLatency: Double?
    public var raw: String { fragments.joined() }
}

public struct HistoryConversation: Codable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let archivedAt: Date?
    public let summaryTitle: String?
    public let titleError: String?
    public var turns: [HistoryTurn] = []
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
        version = 1
        current = HistoryConversation()
        past = []
    }
}

/// UI-owned navigation values; repositories and Agent implementations stay in App.
@MainActor
public struct HistoryAgentDestination: Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let state: ConversationHistoryState
    public let controls: any ConversationHistoryControlling
    public init(
        id: String, name: String, summary: String, state: ConversationHistoryState,
        controls: any ConversationHistoryControlling
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.state = state
        self.controls = controls
    }
}

extension ConversationHistoryControlling {
    public var agents: [HistoryAgentDestination] { [] }
}
