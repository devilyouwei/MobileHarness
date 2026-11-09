import Foundation
import StorageCore

public protocol WriterMessageRepository: Sendable {
    var storageScope: UUID { get }
    func current() async throws -> WriterHistoryMetadata
    func ownerMetadata(_ id: String) async throws -> WriterHistoryMetadata
    func beginMessage(ownerID id: String, identity: WriterMessageIdentity) async throws -> String
    @discardableResult func save(
        ownerID id: String, revision: UInt64, messages: [WriterMessageRecord]
    ) async throws -> [WriterMessageReference]
    func messagePage(ownerID id: String, after: Int64?, limit: Int) async throws -> WriterMessagePage
    func messages(ownerID id: String, after: Int64?, limit: Int) async throws
        -> [WriterMessageRecord]
    func previews(ownerID id: String, after: UInt64, limit: Int, offset: Int)
        async throws -> [WriterMessagePreview]
    func previews(ownerID id: String, before: UInt64?, limit: Int) async throws -> [WriterMessagePreview]
    func messageEvidence(_ id: String) async throws -> [WriterMessageRecord]
    func detailContext(_ id: String, toolCallIDs: [String]) async throws -> WriterMessageDetailContext
    func latestPreviews(ownerID id: String, limit: Int) async throws -> [WriterMessagePreview]
    func unfinishedUserMessages(ownerID id: String) async throws -> [WriterMessageRecord]
    func timelineCount(ownerID id: String) async throws -> Int
    func taskForInput(_ input: String) async throws -> String?
    func inputRows(_ input: String, ownerID id: String) async throws -> [WriterMessageRecord]
    func taskForMessage(_ id: String) async throws -> String
}

extension WriterMessageRepository {
    public func messages(ownerID id: String, after: Int64?) async throws -> [WriterMessageRecord] {
        try await messages(ownerID: id, after: after, limit: 50)
    }
    public func latestPreviews(ownerID id: String) async throws -> [WriterMessagePreview] {
        try await latestPreviews(ownerID: id, limit: 10)
    }
}
