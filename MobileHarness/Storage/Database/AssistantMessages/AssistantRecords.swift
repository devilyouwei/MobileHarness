import Foundation
import StorageCore
import StorageTasks

public enum AssistantHistoryError: Error, Equatable, Sendable {
    case busy, capacityExceeded, invalidRecord, missingTurn, emptyConversation, conflict
}

/// Exact per-request Skill, task and selected State evidence.
public struct AssistantDecisionMetadata: Codable, Sendable {
    public var delegateID: String? = nil
    public var states: [String]? = nil
    public let taskID: String?
    public let mode: String
    public let skills: [String: Int]
    public var catalogJSON: String
    public let taskGoal: String?
    public let execution: String?
    public init(
        taskID: String?, mode: String, skills: [String: Int], catalogJSON: String, taskGoal: String? = nil,
        execution: String? = nil, states: [String]? = nil
    ) {
        self.states = states
        self.taskGoal = taskGoal
        self.execution = execution
        self.taskID = taskID
        self.mode = mode
        self.skills = skills
        self.catalogJSON = catalogJSON
    }
}

/// One model invocation, nested under the input that owns its execution lifecycle.
public struct AssistantModelRequest: Codable, Sendable, Identifiable {
    /// Prepared in memory; cleared only when the provider actually starts.
    public var awaitingDispatch: Bool? = nil
    public var logsCleared: Bool? = nil
    public var requestParametersJSON: String? = nil
    public var responseEventsJSON: String? = nil
    public var producerMetadata: [String: String]? = nil
    public var messageID: String? = nil
    public var inputMessageID: String? = nil
    public var isObservation: Bool? = nil
    public let id: String
    public var date: Date
    public var input: String
    public var requestJSON: String
    public var historyOrder: UInt64 = 0
    public var historyTaskID: String?
    public var decisionMetadata: AssistantDecisionMetadata?
    public var modelRequestStartedAt: Date?
    public var modelRequestCompletedAt: Date?
    public var firstTokenLatency: Double?
    public var firstTokenAt: Date?
    public var response: String = ""
    public var toolCalls: [ModelToolCall] = []
    public var tokenUsage: ModelTokenUsage?
    public var state: AssistantRecord.State = .generating
    public var finishReason: String?
    public var error: String?
    public var failureDiagnostic: ModelFailureDiagnostic?
    public init(
        id: String, input: String, requestJSON: String, decisionMetadata: AssistantDecisionMetadata? = nil,
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

/// Optional additive input evidence; a batch has one response owner and preserves every source.
public struct AssistantInputCoordination: Codable, Sendable {
    public struct Member: Codable, Sendable {
        public let id: String
        public let source: String
        public let capturedAt: String
        public let decision: String?
        public let route: String?

        public init(id: String, evidence: AssistantInputCoordination) {
            self.id = id
            source = evidence.source
            capturedAt = evidence.capturedAt
            decision = evidence.decision
            route = evidence.route
        }
    }

    public let source: String
    public let capturedAt: String
    public var decision: String?
    public var route: String?
    public var batchID: String?
    public var memberIDs: [String]?
    public var members: [Member]?
    public init(source: String, capturedAt: String) {
        self.source = source
        self.capturedAt = capturedAt
    }
}

public struct AssistantRecord: Codable, Sendable, Identifiable {
    public var coordination: AssistantInputCoordination? = nil
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
    public var modelRequests: [AssistantModelRequest]?
    public var generationRounds: [ModelGenerationRound]?
    public var toolDefinitions: [String]?
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
public struct AssistantHistoryReference: Codable, Sendable, Equatable, Hashable {
    public let inputID: String
    public let requestID: String
    public init(inputID: String, requestID: String) {
        self.inputID = inputID
        self.requestID = requestID
    }
}

/// A separately persisted terminal record. Summary is model-reported; status/failure are host facts.
public struct AssistantTaskCompression: Codable, Sendable, Identifiable {
    public var id: String { taskID }
    public let taskID: String
    public let goal: String
    public let status: AssistantRecord.State
    public let reportedSummary: String?
    public let failure: String?
    public let completedAt: Date
    public let sources: [AssistantHistoryReference]
    public let closedAtAction: Bool?
    public init(
        taskID: String, goal: String, status: AssistantRecord.State, reportedSummary: String?, failure: String?,
        completedAt: Date, sources: [AssistantHistoryReference], closedAtAction: Bool? = nil
    ) {
        self.taskID = taskID
        self.goal = goal
        self.status = status
        self.reportedSummary = reportedSummary
        self.failure = failure
        self.completedAt = completedAt
        self.sources = sources
        self.closedAtAction = closedAtAction
    }
}

/// Structural read projection; callers own prompt selection and rendering.
public enum AssistantHistoryItem: Sendable {
    case request(input: AssistantRecord, request: AssistantModelRequest)
    case task(AssistantTaskCompression)
}

public struct AssistantConversation: Codable, Sendable, Identifiable {
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
    public var turns: [AssistantRecord] = []
    public var taskCompressions: [AssistantTaskCompression] = []
    public init(id: String, createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
    }
}

public struct AssistantArchive: Codable, Sendable {
    public let version: Int
    public var revision: UInt64 = 0
    public var current: AssistantConversation
    public var past: [AssistantConversation]
    public init(current: AssistantConversation = AssistantConversation(id: "draft")) {
        version = 4
        self.current = current
        past = []
    }
}

/// Process-local read fence; tokens cannot be constructed outside StorageChat.
public struct AssistantReadToken: Sendable, Equatable {
    internal let value: String
}

public struct AssistantReadSnapshot: Sendable {
    public let current: AssistantConversation
    public let token: AssistantReadToken
}
