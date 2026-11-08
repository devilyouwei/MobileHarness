import Foundation
import StorageCore

public protocol AssistantTaskSummaryRepository: Sendable {
    var storageScope: UUID { get }
    func compressionData(dialog id: String, taskIDs: [String]?) async throws -> [Data]
    func taskSources(_ id: String) async throws -> [TaskSourceRecord]
}

extension AssistantTaskSummaryRepository {
    public func compressionData(dialog id: String) async throws -> [Data] {
        try await compressionData(dialog: id, taskIDs: nil)
    }
}
