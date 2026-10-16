import Foundation
import StorageCore

public protocol TaskRepository: Sendable {
    var storageScope: UUID { get }
    func createTask(
        dialog id: String?, agent: String, goal: String, executor: String?, execution: String,
        parent: String?
    ) async throws -> String
    func endTask(_ id: String, status: String, failure: String?, finishedAt: Date) async throws
}

extension TaskRepository {
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
