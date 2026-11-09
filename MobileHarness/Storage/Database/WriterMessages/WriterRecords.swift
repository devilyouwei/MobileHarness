import Foundation
import StorageCore

public enum WriterHistoryError: Error, Equatable, Sendable {
    case busy, capacityExceeded, invalidRecord, missingTurn, conflict
}

/// Writer phase, workspace and tool catalog evidence.
public struct WriterDecisionMetadata: Codable, Sendable {
    public var delegateID: String? = nil
    public let workspaceID: String?
    public let mode: String
    public let skills: [String: Int]
    public var catalogJSON: String
    public let delegationGoal: String?
    public let execution: String?
    public init(
        workspaceID: String?, mode: String, skills: [String: Int], catalogJSON: String, delegationGoal: String? = nil,
        execution: String? = nil
    ) {
        self.delegationGoal = delegationGoal
        self.execution = execution
        self.workspaceID = workspaceID
        self.mode = mode
        self.skills = skills
        self.catalogJSON = catalogJSON
    }
}

/// Current user/tool input only; complete prompts and image bytes belong to request logs.
public struct WriterInputMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, tool }
    public let role: Role
    public let content: String
    public let toolCallID: String?
    public let toolName: String?
    public init(role: Role, content: String, toolCallID: String? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolName = toolName
    }
    public var contentBytes: Int {
        content.utf8.count + (toolCallID?.utf8.count ?? 0) + (toolName?.utf8.count ?? 0)
    }
}

/// One model invocation, nested under the input that owns its execution lifecycle.
public struct WriterModelRequest: Codable, Sendable, Identifiable {
    public var inputMessages: [WriterInputMessage]? = nil
    public var logsCleared: Bool? = nil
    public var requestParametersJSON: String? = nil
    public var responseEventsJSON: String? = nil
    public var producerMetadata: [String: String]? = nil
    public var model: String? = nil
    public var maximumOutputTokens: Int? = nil
    public var temperature: Double? = nil
    public var messageID: String? = nil
    public var inputMessageID: String? = nil
    public var isObservation: Bool? = nil
    public let id: String
    public let date: Date
    public var input: String
    public var requestJSON: String
    public var historyOrder: UInt64 = 0
    public var decisionMetadata: WriterDecisionMetadata?
    public var modelRequestStartedAt: Date?
    public var modelRequestCompletedAt: Date?
    public var firstTokenLatency: Double?
    public var firstTokenAt: Date?
    public var response: String = ""
    public var toolCalls: [ModelToolCall] = []
    public var tokenUsage: ModelTokenUsage?
    public var state: WriterRecord.State = .generating
    public var finishReason: String?
    public var error: String?
    public var failureDiagnostic: ModelFailureDiagnostic?
    public init(
        id: String, input: String, requestJSON: String, decisionMetadata: WriterDecisionMetadata? = nil,
        date: Date = Date()
    ) {
        self.decisionMetadata = decisionMetadata
        self.id = id
        self.date = date
        self.input = input
        self.requestJSON = requestJSON
    }
}

public struct WriterRecord: Codable, Sendable, Identifiable {
    public var messageID: String? = nil
    public var historyOrder: UInt64 = 0
    public enum State: String, Codable, Sendable { case generating, completed, failed, cancelled, interrupted }
    public let id: String
    public let date: Date
    public var user: String
    public var request: [ModelMessage]
    public var awaitingModel: Bool = false
    public var model: String
    public let maximumOutputTokens: Int?
    public let temperature: Double
    public var modelRequests: [WriterModelRequest]?
    public var generationRounds: [ModelGenerationRound]?
    public var toolCalls: [ModelToolCall]?
    public var tokenUsage: ModelTokenUsage?
    public var response: String = ""
    public var state: State = .generating
    public var finishReason: String?
    public var error: String?
    public var failureDiagnostic: ModelFailureDiagnostic?
    public var executionError: String?
    public var raw: String { response }
    public init(
        id: String, date: Date, user: String, request: [ModelMessage], model: String, maximumOutputTokens: Int?,
        temperature: Double
    ) {
        self.id = id
        self.date = date
        self.user = user
        self.request = request
        self.model = model
        self.maximumOutputTokens = maximumOutputTokens
        self.temperature = temperature
    }
}

/// Stable raw-history address, independent of array positions and archive location.

/// A separately persisted terminal record. Summary is model-reported; status/failure are host facts.

/// Structural read projection; callers own prompt selection and rendering.

public struct WriterHistorySnapshot: Codable, Sendable, Identifiable {
    public var nextPosition: UInt64? = nil
    public var isWindow = false
    public let id: String
    public let createdAt: Date
    public var archivedAt: Date?
    public var summaryTitle: String?
    public var titleError: String?
    public var turnCount: Int?
    public var latestUser: String?
    public var inputIDs: [String]?
    public var turns: [WriterRecord] = []
    public init(id: String, createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
    }
}

struct WriterJournal: Sendable {
    public var revision: UInt64 = 0
    public var current: WriterHistorySnapshot
    public init(current: WriterHistorySnapshot = WriterHistorySnapshot(id: "draft")) {
        self.current = current
    }
}

/// Process-local read fence; tokens cannot be constructed outside StorageChat.
public struct WriterReadToken: Sendable, Equatable {
    internal let value: String
}

public struct WriterReadSnapshot: Sendable {
    public let current: WriterHistorySnapshot
    public let token: WriterReadToken
}
