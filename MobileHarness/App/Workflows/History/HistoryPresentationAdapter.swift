import ActionRuntime
import Actions
import Foundation
import StorageChat
import UI

/// Data adaptation only; permission and user intent belong to the gateways/Agent.
@MainActor
public final class HistoryPresentationAdapter: HistoryPresentationCapability {
    private let state: ConversationHistoryState
    private let store: ConversationHistoryStore
    private let sessionID: UUID
    public init(state: ConversationHistoryState, store: ConversationHistoryStore, sessionID: UUID) {
        self.state = state
        self.store = store
        self.sessionID = sessionID
    }
    public func showHistory(invocation: ToolInvocation) async throws {
        guard invocation.context.source == "conversationMemory", invocation.context.sessionID == sessionID else {
            throw HistoryIntentFailure.execution("Invalid history presentation scope")
        }
        try Task.checkCancellation()
        let snapshot = try await store.snapshot()
        try Task.checkCancellation()
        state.archive = snapshot
        state.status = nil
    }
}
