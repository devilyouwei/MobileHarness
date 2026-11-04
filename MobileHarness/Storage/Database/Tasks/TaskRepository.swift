import Foundation
import StorageCore

public protocol TaskRepository: Sendable {
    var storageScope: UUID { get }
    func createTask(
        dialog id: String?, agent: String, goal: String, executor: String?, execution: String,
        parent: String?
    ) async throws -> String
    func beginDelegation(taskID: String?, goal: String, input: String, sourceDialog: String?, agent: String)
        async throws -> DelegatedTaskRecord
    func delegatedTasks(agent: String, before: Int64?, limit: Int) async throws -> [DelegatedTaskRecord]
    func delegatedTask(_ id: String, agent: String) async throws -> DelegatedTaskRecord
    func delegatedRuns(_ id: String, agent: String) async throws -> [DelegatedRunRecord]
    func delegatedRun(_ runID: String, agent: String) async throws -> DelegatedRunRecord
    func completeDelegatedRun(_ notification: TaskNotification, status: String, failure: String?) async throws
    func taskNotification(_ runID: String, agent: String) async throws -> TaskNotification?
    func pendingTaskNotifications(agent: String, retirement: Bool, after: Int64?, limit: Int) async throws
        -> [TaskNotification]
    func finishTaskNotification(_ runID: String, agent: String, retirement: Bool, completed: Bool, failure: String?)
        async throws
    func bindProject(_ project: String, taskID: String, runID: String, agent: String, ready: Bool) async throws
    func setDelegationPhase(taskID: String, runID: String, phase: String, agent: String) async throws
    func requestCancellation(runID: String, reason: String) async throws
    func endTask(_ id: String, status: String, failure: String?, finishedAt: Date) async throws
}

extension TaskRepository {
    public func delegatedRun(_ runID: String, agent: String) async throws -> DelegatedRunRecord {
        throw RecordStorageError.missingRecord
    }
    public func completeDelegatedRun(_ notification: TaskNotification, status: String, failure: String?) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func taskNotification(_ runID: String, agent: String) async throws -> TaskNotification? {
        throw RecordStorageError.invalidRecord
    }
    public func pendingTaskNotifications(agent: String, retirement: Bool, after: Int64?, limit: Int) async throws
        -> [TaskNotification]
    {
        throw RecordStorageError.invalidRecord
    }
    public func finishTaskNotification(
        _ runID: String, agent: String, retirement: Bool, completed: Bool, failure: String?
    ) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func bindProject(_ project: String, taskID: String, runID: String, agent: String) async throws {
        try await bindProject(project, taskID: taskID, runID: runID, agent: agent, ready: true)
    }

    public func beginDelegation(taskID: String?, goal: String, input: String, sourceDialog: String?, agent: String)
        async throws -> DelegatedTaskRecord
    { throw RecordStorageError.invalidRecord }
    public func delegatedTasks(agent: String, before: Int64?, limit: Int) async throws -> [DelegatedTaskRecord] {
        throw RecordStorageError.invalidRecord
    }
    public func delegatedTask(_ id: String, agent: String) async throws -> DelegatedTaskRecord {
        throw RecordStorageError.missingRecord
    }
    public func delegatedRuns(_ id: String, agent: String) async throws -> [DelegatedRunRecord] {
        throw RecordStorageError.missingRecord
    }
    public func bindProject(_ project: String, taskID: String, runID: String, agent: String, ready: Bool) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func setDelegationPhase(taskID: String, runID: String, phase: String, agent: String) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func requestCancellation(runID: String, reason: String) async throws {
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

/// Stable delegated work and its latest execution. Execution IDs remain ordinary Task record IDs.
public struct DelegatedTaskRecord: Codable, Sendable, Identifiable {
    public var workspaceReady: Bool = false
    public var phase: String? = nil
    public let id: String
    public let dialogID: String
    public let goal: String
    public let projectID: String?
    public let runID: String
    public let status: String
    public let failure: String?
    public let updatedAt: Date
    public init(
        id: String, dialogID: String, goal: String, projectID: String?, runID: String, status: String, failure: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.dialogID = dialogID
        self.goal = goal
        self.projectID = projectID
        self.runID = runID
        self.status = status
        self.failure = failure
        self.updatedAt = updatedAt
    }
}
public struct DelegatedRunRecord: Codable, Sendable, Identifiable {
    public var id: String { runID }
    public let taskID: String
    public let runID: String
    public let goal: String
    public let input: String
    public let status: String
    public let cancellationReason: String?
    public let failure: String?
    public let createdAt: Date
    public init(
        taskID: String, runID: String, goal: String, input: String, status: String, cancellationReason: String?,
        createdAt: Date, failure: String? = nil
    ) {
        self.failure = failure
        self.taskID = taskID
        self.runID = runID
        self.goal = goal
        self.input = input
        self.status = status
        self.cancellationReason = cancellationReason
        self.createdAt = createdAt
    }
}

/// Opaque task completion evidence; execution and user-notification delivery have independent receipts.
public struct TaskNotification: Sendable {
    public let runID: String
    public let agent: String
    public let eventID: String
    public let data: Data
    public let delivered: Bool
    public let retired: Bool
    public init(
        runID: String, agent: String, eventID: String, data: Data, delivered: Bool = false, retired: Bool = false
    ) {
        self.runID = runID
        self.agent = agent
        self.eventID = eventID
        self.data = data
        self.delivered = delivered
        self.retired = retired
    }
}
