import Foundation
import StorageCore

public protocol AgentMessageRepository: Sendable {
    var storageScope: UUID { get }
    func rejectDelegation(_ id: String, failure: String) async throws
    func enqueueAgentMessage(_ value: AgentCommunicationRecord) async throws
    func nextAgentDelivery(sender: String, contract: String) async throws -> Date?
    func agentReply(to id: String, contract: String) async throws -> AgentCommunicationRecord?
    func agentMessage(_ id: String) async throws -> AgentCommunicationRecord?
    func receiveAgentMessage(_ id: String, receiver: String, consumed: Bool) async throws
    func failAgentMessage(_ id: String, failure: String) async throws
}

extension AgentMessageRepository {
    public func rejectDelegation(_ id: String, failure: String) async throws { throw RecordStorageError.invalidRecord }
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
    public func receiveAgentMessage(_ id: String, receiver: String, consumed: Bool) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func failAgentMessage(_ id: String, failure: String) async throws { throw RecordStorageError.invalidRecord }
}
