import Foundation
import StorageCore

public protocol AgentMessageRepository: Sendable {
    var storageScope: UUID { get }
    func archiveInvocationEvidence(_ id: String, ownerContext: String, data: Data) async throws
    func invocationEvidence(_ id: String) async throws -> Data
    func enqueueAgentMessage(_ value: AgentCommunicationRecord) async throws
    func agentMessage(_ id: String) async throws -> AgentCommunicationRecord?
    func isAgentMessageConsumed(_ id: String) async throws -> Bool
    func associateAgentMessage(_ id: String, receiver: String, replyTo: String) async throws
    func receiveAgentMessage(_ id: String, receiver: String, consumed: Bool) async throws
}

extension AgentMessageRepository {
    public func archiveInvocationEvidence(_ id: String, ownerContext: String, data: Data) async throws {
        throw RecordStorageError.invalidRecord
    }
    public func invocationEvidence(_ id: String) async throws -> Data { throw RecordStorageError.invalidRecord }
    public func enqueueAgentMessage(_ value: AgentCommunicationRecord) async throws {
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
}
