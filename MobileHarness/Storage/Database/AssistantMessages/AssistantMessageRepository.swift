import Foundation
import StorageCore

public protocol AssistantMessageRepository: Sendable {
    var storageScope: UUID { get }
    func beginMessage(dialog id: String, identity: AssistantMessageIdentity) async throws -> String
    @discardableResult func save(
        dialog id: String, revision: UInt64, messages: [AssistantMessageRecord],
        summaries: [TaskCompressionRecord]
    ) async throws -> [AssistantMessageReference]
    func messagePage(dialog id: String, after: Int64?, limit: Int) async throws -> AssistantMessagePage
    func messages(dialog id: String, after: Int64?, limit: Int) async throws
        -> [AssistantMessageRecord]
    func previews(dialog id: String, after: UInt64, taskID: String?, limit: Int, offset: Int)
        async throws -> [AssistantMessagePreview]
    func messageEvidence(_ id: String) async throws -> [AssistantMessageRecord]
    func latestPreviews(dialog id: String, limit: Int) async throws -> [AssistantMessagePreview]
    func unfinishedUserMessages(dialog id: String) async throws -> [AssistantMessageRecord]
    func timelineCount(dialog id: String) async throws -> Int
    func titleRows(dialog id: String, positions: [Int]) async throws -> [AssistantMessagePreview]
    func dialogForInput(_ input: String) async throws -> String?
    func inputRows(_ input: String, dialog id: String) async throws -> [AssistantMessageRecord]
    func dialogForMessage(_ id: String) async throws -> String
}

extension AssistantMessageRepository {
    public func messages(dialog id: String, after: Int64?) async throws -> [AssistantMessageRecord] {
        try await messages(dialog: id, after: after, limit: 50)
    }
    public func latestPreviews(dialog id: String) async throws -> [AssistantMessagePreview] {
        try await latestPreviews(dialog: id, limit: 10)
    }
}
