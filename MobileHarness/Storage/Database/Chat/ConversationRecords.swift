import Foundation
import StorageCore
import StorageTasks

/// Producer-classified evidence. Storage persists values without interpreting Agent/provider policy.
public struct ConversationFailureDiagnostic: Codable, Sendable, Equatable {
    public let category: String
    public let code: String
    public let stage: String
    public let message: String
    public let details: [String: String]
    public let causes: [ConversationFailureDiagnostic]
    public init(
        category: String, code: String, stage: String, message: String,
        details: [String: String] = [:], causes: [ConversationFailureDiagnostic] = []
    ) {
        self.category = category
        self.code = code
        self.stage = stage
        self.message = message
        self.details = details
        self.causes = causes
    }
}

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
    public let cachedInput: Int?
    public let cacheWriteInput: Int?
    public init(
        input: Int, generated: Int, total: Int, cachedInput: Int? = nil, cacheWriteInput: Int? = nil
    ) {
        self.input = input
        self.generated = generated
        self.total = total
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
    }
}

public struct ConversationToolCall: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case received, completed, failed, cancelled }
    public let id: String
    public let providerID: String
    public let name: String
    public let argumentsJSON: String
    public var state: State = .received
    public var output: String?
    public var error: String?
    public var failureDiagnostic: ConversationFailureDiagnostic?
    public init(id: String, providerID: String, name: String, argumentsJSON: String) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ConversationGenerationRound: Codable, Sendable, Identifiable {
    public let id: String
    public let resultsJSON: String
    public init(id: String, resultsJSON: String) {
        self.id = id
        self.resultsJSON = resultsJSON
    }
}

/// Exact per-request Skill and task evidence.
public struct ConversationDecisionMetadata: Codable, Sendable {
    public var delegateID: String? = nil
    public let taskID: String?
    public let mode: String
    public let skills: [String: Int]
    public var catalogJSON: String
    public let taskGoal: String?
    public let execution: String?
    public init(
        taskID: String?, mode: String, skills: [String: Int], catalogJSON: String, taskGoal: String? = nil,
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
    public var requestParametersJSON: String? = nil
    public var responseEventsJSON: String? = nil
    public var producerMetadata: [String: String]? = nil
    public var messageID: String? = nil
    public var inputMessageID: String? = nil
    public var isObservation: Bool? = nil
    public let id: String
    public let date: Date
    public var input: String
    public var requestJSON: String
    public var historyOrder: UInt64 = 0
    public var historyTaskID: String?
    public var decisionMetadata: ConversationDecisionMetadata?
    public var modelRequestStartedAt: Date?
    public var modelRequestCompletedAt: Date?
    public var firstTokenLatency: Double?
    public var firstTokenAt: Date?
    public var response: String = ""
    public var toolCalls: [ConversationToolCall] = []
    public var tokenUsage: ConversationTokenUsage?
    public var state: ConversationRecord.State = .generating
    public var finishReason: String?
    public var error: String?
    public var failureDiagnostic: ConversationFailureDiagnostic?
    public init(
        id: String, input: String, requestJSON: String, decisionMetadata: ConversationDecisionMetadata? = nil,
        historyTaskID: String? = nil, date: Date = Date()
    ) {
        self.historyTaskID = historyTaskID
        self.decisionMetadata = decisionMetadata
        self.id = id
        self.date = date
        self.input = input
        self.requestJSON = requestJSON
    }
}

public struct ConversationRecord: Codable, Sendable, Identifiable {
    public var messageID: String? = nil
    public var historyOrder: UInt64 = 0
    public enum State: String, Codable, Sendable { case generating, completed, failed, cancelled, interrupted }
    public let id: String
    public let date: Date
    public var user: String
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
    public var failureDiagnostic: ConversationFailureDiagnostic?
    public var executionError: String?
    public var raw: String { response }
}

/// Stable raw-history address, independent of array positions and archive location.
public struct ConversationHistoryReference: Codable, Sendable, Equatable, Hashable {
    public let inputID: String
    public let requestID: String
    public init(inputID: String, requestID: String) {
        self.inputID = inputID
        self.requestID = requestID
    }
}

/// A separately persisted terminal record. Summary is model-reported; status/failure are host facts.
public struct ConversationTaskCompression: Codable, Sendable, Identifiable {
    public var id: String { taskID }
    public let taskID: String
    public let goal: String
    public let status: ConversationRecord.State
    public let reportedSummary: String?
    public let failure: String?
    public let completedAt: Date
    public let sources: [ConversationHistoryReference]
    public init(
        taskID: String, goal: String, status: ConversationRecord.State, reportedSummary: String?, failure: String?,
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
    public var turns: [ConversationRecord] = []
    public var taskCompressions: [ConversationTaskCompression] = []
    public init(id: String, createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
    }
}

public struct ConversationArchive: Codable, Sendable {
    public let version: Int
    public var revision: UInt64 = 0
    public var current: StoredConversation
    public var past: [StoredConversation]
    public init(current: StoredConversation = StoredConversation(id: "draft")) {
        version = 4
        self.current = current
        past = []
    }
}

/// Process-local read fence; tokens cannot be constructed outside StorageChat.
public struct ConversationReadToken: Sendable, Equatable {
    internal let value: String
}

public struct ConversationReadSnapshot: Sendable {
    public let current: StoredConversation
    public let token: ConversationReadToken
}
