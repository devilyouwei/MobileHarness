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
    public init(state: ConversationHistoryState, store: ConversationHistoryStore, sessionID: UUID) {
        self.state = state
        self.store = store
        self.sessionID = sessionID
    }
    public static func presentationSnapshot(_ snapshot: ConversationArchive) throws -> HistorySnapshot {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= ConversationHistoryStore.maximumBytes else {
            throw HistoryIntentFailure.execution("History snapshot exceeds limit")
        }
        return try JSONDecoder().decode(HistorySnapshot.self, from: data)
    }
    public func showHistory(invocation: any FunctionInput) async throws {
        guard invocation.context.source == "memory", invocation.context.sessionID == sessionID else {
            throw HistoryIntentFailure.execution("Invalid history presentation scope")
        }
        try Task.checkCancellation()
        let snapshot = try await store.snapshot()
        try Task.checkCancellation()
        state.archive = try Self.presentationSnapshot(snapshot)
        state.status = nil
    }
}
