import Actions
import Foundation
import FunctionContracts
import StorageChat
import UI

/// Data adaptation only; permission and user intent belong to the gateways/Agent.
@MainActor
public final class HistoryPresentationAdapter: HistoryPresentationCapability {
    private let state: ConversationHistoryState
    private let store: ConversationHistoryStore
    private let sessionID: UUID
    public init(
        state: ConversationHistoryState, store: ConversationHistoryStore, sessionID: UUID
    ) {
        self.state = state
        self.store = store
        self.sessionID = sessionID
    }
    public static func presentationSnapshot(_ snapshot: ConversationArchive) throws -> HistorySnapshot {
        try snapshot.validate()
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= ConversationHistoryStore.maximumBytes else {
            throw HistoryIntentFailure.execution("History snapshot exceeds limit")
        }
        return try JSONDecoder().decode(HistorySnapshot.self, from: data)
    }
    public static func listPresentation(_ store: ConversationHistoryStore) async throws -> HistorySnapshot {
        let records = try await store.listConversations().map { conversation -> StoredConversation in
            var metadata = conversation
            metadata.turnCount = conversation.turnCount ?? conversation.turns.count
            metadata.latestUser = conversation.latestUser ?? conversation.turns.last.map { String($0.user.prefix(80)) }
            metadata.turns = []
            metadata.taskCompressions = []
            return metadata
        }
        guard let current = records.first else { throw HistoryDetailError.unavailable }
        var archive = ConversationArchive()
        archive.current = current
        archive.past = Array(records.dropFirst())
        return try presentationSnapshot(archive)
    }
    public static func conversation(_ value: StoredConversation) throws -> HistoryConversation {
        try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(value))
    }
    public func showHistory(invocation: any FunctionInput) async throws {
        guard invocation.context.source == "memory", invocation.context.sessionID == sessionID else {
            throw HistoryIntentFailure.execution("Invalid history presentation scope")
        }
        try Task.checkCancellation()
        let presentation = try await Self.listPresentation(store)
        try Task.checkCancellation()
        state.archive = presentation
        state.status = await store.lastCheckpointError.map { "当前会话尚未保存：" + $0 }
    }
}
