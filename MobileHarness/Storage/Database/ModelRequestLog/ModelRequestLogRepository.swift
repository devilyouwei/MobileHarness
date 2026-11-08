import Foundation
import StorageCore

public protocol ModelRequestLogRepository: Sendable {
    var storageScope: UUID { get }
    func writeRequestPayload(
        _ requestID: String, agent: String, json: String, response: String, initial: Bool,
        update: ModelRequestLogUpdate?)
        async throws
    func requestPayload(_ id: String, agent: String) async throws -> ModelRequestLog?
    func clearRequestLogs(agent: String, requestID: String?) async throws
}

extension ModelRequestLogRepository {
    public func writeRequestPayload(
        _ requestID: String, agent: String, json: String, response: String, initial: Bool,
        update: ModelRequestLogUpdate? = nil
    )
        async throws
    { throw RecordStorageError.invalidRecord }
    public func requestPayload(_ id: String, agent: String) async throws -> ModelRequestLog? {
        throw RecordStorageError.invalidRecord
    }
    public func clearRequestLogs(agent: String, requestID: String?) async throws {
        throw RecordStorageError.invalidRecord
    }
}
