import Foundation
import StorageCore

public protocol AgentMessageRepository: Sendable {
    var storageScope: UUID { get }
    func observationRequests(sender: String, after: String?, limit: Int) async throws -> [AgentCommunicationRecord]
    func archiveInvocationEvidence(_ id: String, ownerContext: String, data: Data) async throws
    func invocationEvidence(_ id: String) async throws -> Data
    func taskEvents(reference: String, receiver: String, after: Int64?, limit: Int) async throws -> AgentTaskEventPage
    func consumeTaskEvents(reference: String, receiver: String, through: Int64) async throws
    func rejectAgentMessage(_ id: String, eventID: String, payload: Data) async throws
    func enqueueAgentMessage(_ value: AgentCommunicationRecord) async throws
    func nextAgentDelivery(sender: String, contract: String) async throws -> Date?
    func agentReply(to id: String, contract: String) async throws -> AgentCommunicationRecord?
    func agentMessage(_ id: String) async throws -> AgentCommunicationRecord?
    func isAgentMessageConsumed(_ id: String) async throws -> Bool
    func associateAgentMessage(_ id: String, receiver: String, replyTo: String) async throws
    func receiveAgentMessage(_ id: String, receiver: String, consumed: Bool) async throws
    func failAgentMessage(_ id: String, failure: String) async throws
}

extension AgentMessageRepository {
    public func observationRequests(sender: String, after: String?, limit: Int) async throws
        -> [AgentCommunicationRecord]
    { throw RecordStorageError.invalidRecord }
    public func archiveInvocationEvidence(_ id: String, ownerContext: String, data: Data) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func invocationEvidence(_ id: String) async throws -> Data { throw RecordStorageError.invalidRecord }
    public func taskEvents(reference: String, receiver: String, after: Int64? = nil, limit: Int = 32) async throws
        -> AgentTaskEventPage
    {
        throw RecordStorageError.invalidRecord
    }
    public func consumeTaskEvents(reference: String, receiver: String, through: Int64) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func rejectAgentMessage(_ id: String, eventID: String, payload: Data) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func enqueueAgentMessage(_ value: AgentCommunicationRecord) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func nextAgentDelivery(sender: String, contract: String) async throws -> Date? {
        throw RecordStorageError.invalidRecord
    }
    public func agentReply(to id: String, contract: String) async throws -> AgentCommunicationRecord? {
        throw RecordStorageError.invalidRecord
    }
    public func agentMessage(_ id: String) async throws -> AgentCommunicationRecord? {
        throw RecordStorageError.invalidRecord
    }
    public func isAgentMessageConsumed(_ id: String) async throws -> Bool { throw RecordStorageError.invalidRecord }
    public func associateAgentMessage(_ id: String, receiver: String, replyTo: String) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func receiveAgentMessage(_ id: String, receiver: String, consumed: Bool) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func failAgentMessage(_ id: String, failure: String) async throws { throw RecordStorageError.invalidRecord }
}
