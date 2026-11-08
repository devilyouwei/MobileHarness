import Foundation
import StorageCore

public protocol AssistantTaskRepository: Sendable {
    var storageScope: UUID { get }
    func createTask(
        dialog id: String?, agent: String, goal: String
    ) async throws -> String
    func endTask(_ id: String, status: String, failure: String?, finishedAt: Date) async throws
}

extension AssistantTaskRepository {
    public func endTask(_ id: String, status: String, failure: String?) async throws {
        try await endTask(id, status: status, failure: failure, finishedAt: Date())
    }
    public func endTask(_ id: String, status: String) async throws {
        try await endTask(id, status: status, failure: nil, finishedAt: Date())
    }
}
