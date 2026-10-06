import Foundation
import StorageChat

/// Archive-only mutation validation; persistence remains an atomic Storage transaction.
public struct HistoryMutationService: HistoryMutationCapability {
    private let store: ConversationHistoryStore
    public init(store: ConversationHistoryStore) { self.store = store }
    public func deleteArchived(_ id: UUID) async throws {
        try Task.checkCancellation()
        let snapshot = try await store.snapshot()
        guard snapshot.current.id != id else { throw HistoryQueryError.currentConversation }
        guard snapshot.past.contains(where: { $0.id == id }) else { throw HistoryQueryError.missingConversation }
        try Task.checkCancellation()
        try await store.deleteArchived(id)
    }

}
