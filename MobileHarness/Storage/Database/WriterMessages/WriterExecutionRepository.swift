import Foundation
import StorageCore

public protocol WriterExecutionRepository: Sendable {
    var storageScope: UUID { get }
    func createWorkspace(requestID: String, title: String) async throws -> WriterWorkspaceRecord
    func createWorkspace(requestID: String, title: String, replacing previousWorkspaceID: String) async throws
        -> WriterWorkspaceRecord
    func switchWorkspace(requestID: String, from previousWorkspaceID: String, to workspaceID: String) async throws
    func delegations(before: UInt64?, limit: Int) async throws -> [WriterRequestRecord]
    func delegationCount() async throws -> Int
    func selectWorkspace(requestID: String, workspaceID: String) async throws -> WriterWorkspaceRecord
    func beginRequest(
        delegateID: String, workspaceID: String?, goal: String, input: String, sourceDialog: String?, agent: String
    )
        async throws -> WriterRequestRecord
    func workspaces(agent: String, before: Int64?, limit: Int) async throws -> [WriterWorkspaceRecord]
    func workspace(_ id: String, agent: String) async throws -> WriterWorkspaceRecord
    func requests(_ id: String, agent: String) async throws -> [WriterRequestRecord]
    func requestStatus(_ delegateID: String, agent: String) async throws -> String?
    func request(_ delegateID: String, agent: String) async throws -> WriterRequestRecord
    func completeRequest(_ notification: WriterDelegationNotification, status: String, failure: String?) async throws
    func delegationNotification(_ delegateID: String, agent: String) async throws -> WriterDelegationNotification?
    func pendingDelegationNotifications(agent: String, retirement: Bool, after: Int64?, limit: Int) async throws
        -> [WriterDelegationNotification]
    func finishDelegationNotification(
        _ delegateID: String, agent: String, retirement: Bool, completed: Bool, failure: String?, claimToken: String?)
        async throws
    func prepareWorkspace(workspaceID: String, delegateID: String, agent: String, ready: Bool)
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
    public func createWorkspace(requestID: String, title: String, replacing previousWorkspaceID: String) async throws
        -> WriterWorkspaceRecord
    {
        throw RecordStorageError.invalidRecord
    }
    public func switchWorkspace(requestID: String, from previousWorkspaceID: String, to workspaceID: String)
        async throws
    {
        throw RecordStorageError.invalidRecord
    }
    public func selectWorkspace(requestID: String, workspaceID: String) async throws -> WriterWorkspaceRecord {
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
    public func completeRequest(_ notification: WriterDelegationNotification, status: String, failure: String?)
        async throws
    {
        throw RecordStorageError.invalidRecord
    }
    public func delegationNotification(_ delegateID: String, agent: String) async throws
        -> WriterDelegationNotification?
    {
        throw RecordStorageError.invalidRecord
    }
    public func pendingDelegationNotifications(agent: String, retirement: Bool, after: Int64?, limit: Int) async throws
        -> [WriterDelegationNotification]
    {
        throw RecordStorageError.invalidRecord
    }
    public func finishDelegationNotification(
        _ delegateID: String, agent: String, retirement: Bool, completed: Bool, failure: String?,
        claimToken: String?
    ) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func finishDelegationNotification(
        _ delegateID: String, agent: String, retirement: Bool, completed: Bool, failure: String?
    ) async throws {
        try await finishDelegationNotification(
            delegateID, agent: agent, retirement: retirement, completed: completed, failure: failure, claimToken: nil)
    }
    public func prepareWorkspace(workspaceID: String, delegateID: String, agent: String) async throws {
        try await prepareWorkspace(workspaceID: workspaceID, delegateID: delegateID, agent: agent, ready: true)
    }
    public func beginRequest(
        delegateID: String, workspaceID: String?, goal: String, input: String, sourceDialog: String?, agent: String
    )
        async throws -> WriterRequestRecord
    { throw RecordStorageError.invalidRecord }
    public func workspaces(agent: String, before: Int64?, limit: Int) async throws -> [WriterWorkspaceRecord] {
        throw RecordStorageError.invalidRecord
    }
    public func workspace(_ id: String, agent: String) async throws -> WriterWorkspaceRecord {
        throw RecordStorageError.missingRecord
    }
    public func requests(_ id: String, agent: String) async throws -> [WriterRequestRecord] {
        throw RecordStorageError.missingRecord
    }
    public func prepareWorkspace(workspaceID: String, delegateID: String, agent: String, ready: Bool)
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
