import Foundation
import Storage

/// Shared display-page size; independent of raw record enumeration batches.
public enum HistoryPaging {
    public static let pageSize = 20
}

public struct DialogRecord: Sendable {
    public let id: String
    public let agent: String
    public let createdAt: Date
    public let archivedAt: Date?
    public let title: String?
    public let titleError: String?
    public let revision: UInt64
    public let recovery: Data?
    public let count: Int
    public let latestUser: String?
    public init(
        id: String, agent: String, createdAt: Date, archivedAt: Date?, title: String?, titleError: String?,
        revision: UInt64, recovery: Data?, count: Int, latestUser: String?
    ) {
        self.id = id
        self.agent = agent
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.title = title
        self.titleError = titleError
        self.revision = revision
        self.recovery = recovery
        self.count = count
        self.latestUser = latestUser
    }
}

/// Minimal identity metadata; body/evidence are committed only at the producer's completion boundary.
public struct MessageIdentity: Sendable {
    public let clientID: String
    public let inputID: String
    public let role: String
    public let kind: String
    public let order: UInt64
    public let date: Date
    public let taskID: String?
    public let replyTo: String?
    public init(
        clientID: String, inputID: String, role: String, kind: String, order: UInt64, date: Date,
        taskID: String? = nil, replyTo: String? = nil
    ) {
        self.clientID = clientID
        self.inputID = inputID
        self.role = role
        self.kind = kind
        self.order = order
        self.date = date
        self.taskID = taskID
        self.replyTo = replyTo
    }
}

/// Committed backend identity, returned only after the complete batch transaction succeeds.
public struct MessageReference: Sendable {
    public let id: String
    public let clientID: String
    public let role: String
    public init(id: String, clientID: String, role: String) {
        self.id = id
        self.clientID = clientID
        self.role = role
    }
}

public struct MessageRecord: Sendable {
    public let clientID: String
    public let inputID: String
    public let role: String
    public let kind: String
    public let order: UInt64
    public let date: Date
    public let body: String
    public let state: String
    public let taskID: String?
    public let detail: Data
    public var id: String?
    public init(
        clientID: String, inputID: String, role: String, kind: String, order: UInt64, date: Date,
        body: String, state: String, taskID: String? = nil, detail: Data, id: String? = nil
    ) {
        self.clientID = clientID
        self.inputID = inputID
        self.role = role
        self.kind = kind
        self.order = order
        self.date = date
        self.body = body
        self.state = state
        self.taskID = taskID
        self.detail = detail
        self.id = id
    }
}
public struct TaskCompressionRecord: Sendable {
    public let id: String
    public let goal: String
    public let status: String
    public let summary: String?
    public let failure: String?
    public let finishedAt: Date
    public let sources: [String]
    public let detail: Data
    public init(
        id: String, goal: String, status: String, summary: String?, failure: String?, finishedAt: Date,
        sources: [String], detail: Data
    ) {
        self.id = id
        self.goal = goal
        self.status = status
        self.summary = summary
        self.failure = failure
        self.finishedAt = finishedAt
        self.sources = sources
        self.detail = detail
    }
}
public struct MessagePreview: Sendable {
    public let id: String
    public let clientID: String
    public let inputID: String
    public let input: String
    public let response: String
    public let date: Date
    public let position: UInt64
    public let state: String
    public let taskID: String?
    public let isObservation: Bool
    public let isInput: Bool
    public init(
        id: String, clientID: String, inputID: String, input: String, response: String, date: Date, position: UInt64,
        state: String, taskID: String?, isObservation: Bool, isInput: Bool
    ) {
        self.id = id
        self.clientID = clientID
        self.inputID = inputID
        self.input = input
        self.response = response
        self.date = date
        self.position = position
        self.state = state
        self.taskID = taskID
        self.isObservation = isObservation
        self.isInput = isInput
    }
}

public struct TaskSourceRecord: Sendable {
    public let inputID: String
    public let requestID: String
    public let position: UInt64
    public init(inputID: String, requestID: String, position: UInt64) {
        self.inputID = inputID
        self.requestID = requestID
        self.position = position
    }
}
public protocol ChatRepository: Sendable {
    var storageScope: UUID { get }
    func current(agent: String, includingRecovery: Bool) async throws -> DialogRecord
    func listDialogs(agent: String, before: Int64?, limit: Int) async throws -> [DialogRecord]
    func dialog(_ id: String, includingRecovery: Bool) async throws -> DialogRecord
    func beginMessage(dialog id: String, identity: MessageIdentity) async throws -> String
    @discardableResult func save(
        dialog id: String, revision: UInt64, recovery: Data?, messages: [MessageRecord],
        summaries: [TaskCompressionRecord]
    ) async throws -> [MessageReference]
    func messages(dialog id: String, after: Int64?, limit: Int) async throws
        -> [MessageRecord]
    func compressionData(dialog id: String, taskIDs: [String]?) async throws -> [Data]
    func rotate(_ id: String, agent: String) async throws -> DialogRecord
    func setTitle(_ title: String?, error: String?, dialog id: String) async throws
    func deleteDialog(_ id: String) async throws
    func previews(dialog id: String, after: UInt64, taskID: String?, limit: Int, offset: Int)
        async throws -> [MessagePreview]
    func messageEvidence(_ id: String) async throws -> [MessageRecord]
    func taskSources(_ id: String) async throws -> [TaskSourceRecord]
    func latestPreviews(dialog id: String, limit: Int) async throws -> [MessagePreview]
    func unfinishedUserMessages(dialog id: String) async throws -> [MessageRecord]
    func timelineCount(dialog id: String) async throws -> Int
    func titleRows(dialog id: String, positions: [Int]) async throws -> [MessagePreview]
    func dialogForInput(_ input: String) async throws -> String?
    func inputRows(_ input: String, dialog id: String) async throws -> [MessageRecord]
    func dialogForMessage(_ id: String) async throws -> String
}

extension ChatRepository {
    public func current(agent: String) async throws -> DialogRecord {
        try await current(agent: agent, includingRecovery: true)
    }
    public func dialog(_ id: String) async throws -> DialogRecord { try await dialog(id, includingRecovery: true) }
    public func messages(dialog id: String, after: Int64?) async throws -> [MessageRecord] {
        try await messages(dialog: id, after: after, limit: 50)
    }
    public func compressionData(dialog id: String) async throws -> [Data] {
        try await compressionData(dialog: id, taskIDs: nil)
    }
    public func latestPreviews(dialog id: String) async throws -> [MessagePreview] {
        try await latestPreviews(dialog: id, limit: 10)
    }
}
