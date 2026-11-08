import Foundation
import FunctionContracts
import StorageChat
import StorageCore
import UI

/// Data adaptation only; permission and user intent belong to the gateways/Agent.
@MainActor
public final class HistoryPresentationAdapter: HistoryPresentationCapability {
    private let state: any HistoryPresenting
    private let store: AssistantHistoryStore
    private let sessionID: String
    public init(
        state: any HistoryPresenting, store: AssistantHistoryStore, sessionID: String
    ) {
        self.state = state
        self.store = store
        self.sessionID = sessionID
    }
    public static func presentationSnapshot(_ snapshot: AssistantArchive) throws -> HistorySnapshot {
        try snapshot.validate()
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= AssistantHistoryStore.maximumBytes else {
            throw HistoryPresentationFailure.init("History snapshot exceeds limit")
        }
        return try JSONDecoder().decode(HistorySnapshot.self, from: data)
    }
    public static func listPresentation(_ store: AssistantHistoryStore) async throws -> HistorySnapshot {
        let records = try await store.listConversations().map { conversation -> AssistantConversation in
            var metadata = conversation
            metadata.turnCount = conversation.turnCount ?? conversation.turns.count
            metadata.latestUser = conversation.latestUser ?? conversation.turns.last.map { String($0.user.prefix(80)) }
            metadata.turns = []
            metadata.taskCompressions = []
            return metadata
        }
        guard let current = records.first else { throw HistoryDetailError.unavailable }
        var archive = AssistantArchive()
        archive.current = current
        archive.past = Array(records.dropFirst())
        return try presentationSnapshot(archive)
    }
    public static func conversation(_ value: AssistantConversation) throws -> HistoryConversation {
        try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(value))
    }
    public func refreshAfterMutation(message: String?) async throws {
        let snapshot = try await Self.listPresentation(store)
        try Task.checkCancellation()
        try state.requirePresentation()
        state.present(.archive(snapshot))
        state.present(.status(message))
    }
    public func recordRefreshFailure(_ error: any Error) {
        guard state.isPresentationAvailable else { return }
        state.present(.status("历史刷新失败：\(error)"))
    }
    public func showHistory(invocation: any FunctionInput) async throws {
        guard invocation.context.sessionID == sessionID else {
            throw HistoryPresentationFailure.init("Invalid history presentation scope")
        }
        try Task.checkCancellation()
        let presentation = try await Self.listPresentation(store)
        try Task.checkCancellation()
        let status = await store.lastCheckpointError.map { "当前会话尚未保存：" + $0 }
        try state.requirePresentation()
        state.present(presentation, status: status)
    }
}

private struct HistoryPresentationFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
