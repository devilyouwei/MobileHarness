import Foundation
import StorageCore

public protocol WriterMessageRepository: Sendable {
    var storageScope: UUID { get }
    func current() async throws -> WriterHistoryMetadata
    func taskMetadata(_ id: String) async throws -> WriterHistoryMetadata
    func beginMessage(task id: String, identity: WriterMessageIdentity) async throws -> String
    @discardableResult func save(
        task id: String, revision: UInt64, messages: [WriterMessageRecord]
    ) async throws -> [WriterMessageReference]
    func messagePage(task id: String, after: Int64?, limit: Int) async throws -> WriterMessagePage
    func messages(task id: String, after: Int64?, limit: Int) async throws
        -> [WriterMessageRecord]
    func previews(task id: String, after: UInt64, limit: Int, offset: Int)
        async throws -> [WriterMessagePreview]
    func messageEvidence(_ id: String) async throws -> [WriterMessageRecord]
    func detailContext(_ id: String, toolCallIDs: [String]) async throws -> WriterMessageDetailContext
    func latestPreviews(task id: String, limit: Int) async throws -> [WriterMessagePreview]
    func unfinishedUserMessages(task id: String) async throws -> [WriterMessageRecord]
    func timelineCount(task id: String) async throws -> Int
    func taskForInput(_ input: String) async throws -> String?
    func inputRows(_ input: String, task id: String) async throws -> [WriterMessageRecord]
    func taskForMessage(_ id: String) async throws -> String
}

extension WriterMessageRepository {
    public func messages(task id: String, after: Int64?) async throws -> [WriterMessageRecord] {
        try await messages(task: id, after: after, limit: 50)
    }
    public func latestPreviews(task id: String) async throws -> [WriterMessagePreview] {
        try await latestPreviews(task: id, limit: 10)
    }
}
