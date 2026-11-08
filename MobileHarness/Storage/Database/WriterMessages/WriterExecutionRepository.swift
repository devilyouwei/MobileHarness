import Foundation
import StorageCore

public protocol WriterExecutionRepository: Sendable {
    var storageScope: UUID { get }
    func createWorkspace(requestID: String, title: String) async throws -> WriterWorkspaceRecord
    func delegations(before: UInt64?, limit: Int) async throws -> [WriterRequestRecord]
    func delegationCount() async throws -> Int
    func selectWorkspace(requestID: String, taskID: String) async throws -> WriterWorkspaceRecord
    func beginRequest(
        delegateID: String, taskID: String?, goal: String, input: String, sourceDialog: String?, agent: String
    )
        async throws -> WriterRequestRecord
    func tasks(agent: String, before: Int64?, limit: Int) async throws -> [WriterWorkspaceRecord]
    func task(_ id: String, agent: String) async throws -> WriterWorkspaceRecord
    func requests(_ id: String, agent: String) async throws -> [WriterRequestRecord]
    func requestStatus(_ delegateID: String, agent: String) async throws -> String?
    func request(_ delegateID: String, agent: String) async throws -> WriterRequestRecord
    func completeRequest(_ notification: TaskNotification, status: String, failure: String?) async throws
    func taskNotification(_ delegateID: String, agent: String) async throws -> TaskNotification?
    func pendingTaskNotifications(agent: String, retirement: Bool, after: Int64?, limit: Int) async throws
        -> [TaskNotification]
    func finishTaskNotification(
        _ delegateID: String, agent: String, retirement: Bool, completed: Bool, failure: String?, claimToken: String?)
        async throws
    func prepareWorkspace(_ project: String, taskID: String, delegateID: String, agent: String, ready: Bool)
        async throws
    func updateRequestPhase(requestID: String, phase: String) async throws
    func saveInteraction(delegateID: String, interactionID: String?, data: Data?) async throws
    func acceptWriterInput(_ id: String, requestID: String, text: String, questionID: String?) async throws -> Bool
}

extension WriterExecutionRepository {
    public func delegations(before: UInt64?, limit: Int) async throws -> [WriterRequestRecord] {
        throw RecordStorageError.invalidRecord
    }
    public func delegationCount() async throws -> Int { throw RecordStorageError.invalidRecord }
    public func createWorkspace(requestID: String, title: String) async throws -> WriterWorkspaceRecord {
        throw RecordStorageError.invalidRecord
    }
    public func selectWorkspace(requestID: String, taskID: String) async throws -> WriterWorkspaceRecord {
        throw RecordStorageError.invalidRecord
    }
    public func saveInteraction(delegateID: String, interactionID: String?, data: Data?) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func requestStatus(_ delegateID: String, agent: String) async throws -> String? {
        throw RecordStorageError.invalidRecord
    }
    public func request(_ delegateID: String, agent: String) async throws -> WriterRequestRecord {
        throw RecordStorageError.missingRecord
    }
    public func completeRequest(_ notification: TaskNotification, status: String, failure: String?) async throws {
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
        _ delegateID: String, agent: String, retirement: Bool, completed: Bool, failure: String?,
        claimToken: String?
    ) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func finishTaskNotification(
        _ delegateID: String, agent: String, retirement: Bool, completed: Bool, failure: String?
    ) async throws {
        try await finishTaskNotification(
            delegateID, agent: agent, retirement: retirement, completed: completed, failure: failure, claimToken: nil)
    }
    public func prepareWorkspace(_ project: String, taskID: String, delegateID: String, agent: String) async throws {
        try await prepareWorkspace(project, taskID: taskID, delegateID: delegateID, agent: agent, ready: true)
    }
    public func beginRequest(
        delegateID: String, taskID: String?, goal: String, input: String, sourceDialog: String?, agent: String
    )
        async throws -> WriterRequestRecord
    { throw RecordStorageError.invalidRecord }
    public func tasks(agent: String, before: Int64?, limit: Int) async throws -> [WriterWorkspaceRecord] {
        throw RecordStorageError.invalidRecord
    }
    public func task(_ id: String, agent: String) async throws -> WriterWorkspaceRecord {
        throw RecordStorageError.missingRecord
    }
    public func requests(_ id: String, agent: String) async throws -> [WriterRequestRecord] {
        throw RecordStorageError.missingRecord
    }
    public func prepareWorkspace(_ project: String, taskID: String, delegateID: String, agent: String, ready: Bool)
        async throws
    {
        throw RecordStorageError.invalidRecord
    }
    public func updateRequestPhase(requestID: String, phase: String) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func acceptWriterInput(_ id: String, requestID: String, text: String, questionID: String?) async throws
        -> Bool
    {
        throw RecordStorageError.invalidRecord
    }
}
