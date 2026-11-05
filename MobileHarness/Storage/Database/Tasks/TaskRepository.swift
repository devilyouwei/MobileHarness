import Foundation
import StorageCore

public protocol TaskRepository: Sendable {
    var storageScope: UUID { get }
    func createTask(
        dialog id: String?, agent: String, goal: String, executor: String?, execution: String,
        parent: String?
    ) async throws -> String
    func createDelegation(
        id: String, requester: String, executor: String, goal: String, input: String, sourceDialog: String?)
        async throws
    func rejectDelegation(_ id: String, failure: String) async throws
    func beginDelegation(
        delegateID: String, taskID: String?, goal: String, input: String, sourceDialog: String?, agent: String
    )
        async throws -> DelegatedTaskRecord
    func delegatedTasks(agent: String, before: Int64?, limit: Int) async throws -> [DelegatedTaskRecord]
    func delegatedTask(_ id: String, agent: String) async throws -> DelegatedTaskRecord
    func delegations(_ id: String, agent: String) async throws -> [DelegationRecord]
    func delegationStatus(_ delegateID: String, agent: String) async throws -> String?
    func delegation(_ delegateID: String, agent: String) async throws -> DelegationRecord
    func completeDelegation(_ notification: TaskNotification, status: String, failure: String?) async throws
    func taskNotification(_ delegateID: String, agent: String) async throws -> TaskNotification?
    func pendingTaskNotifications(agent: String, retirement: Bool, after: Int64?, limit: Int) async throws
        -> [TaskNotification]
    func finishTaskNotification(
        _ delegateID: String, agent: String, retirement: Bool, completed: Bool, failure: String?)
        async throws
    func prepareWorkspace(_ project: String, taskID: String, delegateID: String, agent: String, ready: Bool)
        async throws
    func setDelegationPhase(taskID: String, delegateID: String, phase: String, agent: String) async throws
    func saveInteraction(delegateID: String, interactionID: String?, data: Data?) async throws
    func requestCancellation(delegateID: String, reason: String) async throws
    func endTask(_ id: String, status: String, failure: String?, finishedAt: Date) async throws
}

extension TaskRepository {
    public func saveInteraction(delegateID: String, interactionID: String?, data: Data?) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func createDelegation(
        id: String, requester: String, executor: String, goal: String, input: String, sourceDialog: String?
    ) async throws { throw RecordStorageError.invalidRecord }
    public func rejectDelegation(_ id: String, failure: String) async throws { throw RecordStorageError.invalidRecord }

    public func delegationStatus(_ delegateID: String, agent: String) async throws -> String? {
        throw RecordStorageError.invalidRecord
    }
    public func delegation(_ delegateID: String, agent: String) async throws -> DelegationRecord {
        throw RecordStorageError.missingRecord
    }
    public func completeDelegation(_ notification: TaskNotification, status: String, failure: String?) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func taskNotification(_ delegateID: String, agent: String) async throws -> TaskNotification? {
        throw RecordStorageError.invalidRecord
    }
    public func pendingTaskNotifications(agent: String, retirement: Bool, after: Int64?, limit: Int) async throws
        -> [TaskNotification]
    {
        throw RecordStorageError.invalidRecord
    }
    public func finishTaskNotification(
        _ delegateID: String, agent: String, retirement: Bool, completed: Bool, failure: String?
    ) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func prepareWorkspace(_ project: String, taskID: String, delegateID: String, agent: String) async throws {
        try await prepareWorkspace(project, taskID: taskID, delegateID: delegateID, agent: agent, ready: true)
    }

    public func beginDelegation(
        delegateID: String, taskID: String?, goal: String, input: String, sourceDialog: String?, agent: String
    )
        async throws -> DelegatedTaskRecord
    { throw RecordStorageError.invalidRecord }
    public func delegatedTasks(agent: String, before: Int64?, limit: Int) async throws -> [DelegatedTaskRecord] {
        throw RecordStorageError.invalidRecord
    }
    public func delegatedTask(_ id: String, agent: String) async throws -> DelegatedTaskRecord {
        throw RecordStorageError.missingRecord
    }
    public func delegations(_ id: String, agent: String) async throws -> [DelegationRecord] {
        throw RecordStorageError.missingRecord
    }
    public func prepareWorkspace(_ project: String, taskID: String, delegateID: String, agent: String, ready: Bool)
        async throws
    {
        throw RecordStorageError.invalidRecord
    }
    public func setDelegationPhase(taskID: String, delegateID: String, phase: String, agent: String) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func requestCancellation(delegateID: String, reason: String) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func createTask(dialog id: String?, agent: String, goal: String) async throws -> String {
        try await createTask(dialog: id, agent: agent, goal: goal, executor: nil, execution: "foreground", parent: nil)
    }
    public func endTask(_ id: String, status: String, failure: String?) async throws {
        try await endTask(id, status: status, failure: failure, finishedAt: Date())
    }
    public func endTask(_ id: String, status: String) async throws {
        try await endTask(id, status: status, failure: nil, finishedAt: Date())
    }
}

/// Agent-owned workspace task and a projection of its latest delegation, never a permanent task completion.
public struct DelegatedTaskRecord: Codable, Sendable, Identifiable {
    public var workspaceReady: Bool = false
    public var phase: String? = nil
    public let id: String
    public let dialogID: String
    public let goal: String
    public let agentID: String
    public var workspaceID: String { agentID + "/" + id }
    public let delegateID: String
    public let status: String
    public let failure: String?
    public let updatedAt: Date
    public init(
        id: String, dialogID: String, goal: String, agentID: String, delegateID: String, status: String,
        failure: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.dialogID = dialogID
        self.goal = goal
        self.agentID = agentID
        self.delegateID = delegateID
        self.status = status
        self.failure = failure
        self.updatedAt = updatedAt
    }
}
public struct DelegationRecord: Codable, Sendable, Identifiable {
    public var id: String { delegateID }
    public let taskID: String
    public let delegateID: String
    public let goal: String
    public let input: String
    public let status: String
    public let cancellationReason: String?
    public let failure: String?
    public let createdAt: Date
    public let finishedAt: Date?
    public init(
        taskID: String, delegateID: String, goal: String, input: String, status: String, cancellationReason: String?,
        createdAt: Date, failure: String? = nil, finishedAt: Date? = nil
    ) {
        self.finishedAt = finishedAt
        self.failure = failure
        self.taskID = taskID
        self.delegateID = delegateID
        self.goal = goal
        self.input = input
        self.status = status
        self.cancellationReason = cancellationReason
        self.createdAt = createdAt
    }
}

/// Opaque task completion evidence; execution and user-notification delivery have independent receipts.
public struct TaskNotification: Sendable {
    public let delegateID: String
    public let position: Int64
    public let agent: String
    public let eventID: String
    public let data: Data
    public let delivered: Bool
    public let retired: Bool
    public init(
        delegateID: String, agent: String, eventID: String, data: Data, delivered: Bool = false, retired: Bool = false,
        position: Int64 = 0
    ) {
        self.delegateID = delegateID
        self.agent = agent
        self.eventID = eventID
        self.data = data
        self.position = position
        self.delivered = delivered
        self.retired = retired
    }
}
