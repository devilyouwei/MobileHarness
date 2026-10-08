import Foundation
import FunctionContracts
import StorageChat

/// Archive-only mutation validation; persistence remains an atomic Storage transaction.
public struct HistoryMutationService: HistoryMutationCapability {
    private let store: ConversationHistoryStore
    private let summarizeTitle: @Sendable (StoredConversation) async throws -> String
    public init(
        store: ConversationHistoryStore, summarizeTitle: @escaping @Sendable (StoredConversation) async throws -> String
    ) {
        self.store = store
        self.summarizeTitle = summarizeTitle
    }
    public func startNew() async throws -> UUID? {
        try Task.checkCancellation()
        return try await store.startNew()?.id
    }
    public func summarizeArchived(_ id: UUID) async throws {
        try Task.checkCancellation()
        let snapshot = try await store.snapshot()
        guard snapshot.current.id != id else { throw HistoryQueryError.currentConversation }
        guard let conversation = snapshot.past.first(where: { $0.id == id }) else {
            throw HistoryQueryError.missingConversation
        }
        do {
            try Task.checkCancellation()
            let title = try await summarizeTitle(conversation)
            try Task.checkCancellation()
            try await store.setTitle(title, for: id)
        } catch {
            let generationError = error
            do {
                // Retain retry evidence even when the caller cancelled; persistence joins before return.
                try await store.setTitle(nil, error: String(String(describing: generationError).prefix(1024)), for: id)
            } catch {
                let report = try ActionReport(entries: [
                    .init(
                        path: "title", status: generationError is CancellationError ? .cancelled : .failed,
                        code: ActionReport.code(for: generationError),
                        details: [
                            "failureDescription": String(ActionReport.description(for: generationError).prefix(128))
                        ]),
                    .init(
                        path: "retryState", status: .failed, code: ActionReport.code(for: error),
                        details: ["failureDescription": String(ActionReport.description(for: error).prefix(128))]),
                ])
                throw ActionReportedError(report)
            }
            throw generationError
        }
    }
    public func deleteArchived(_ id: UUID) async throws {
        try Task.checkCancellation()
        let snapshot = try await store.snapshot()
        guard snapshot.current.id != id else { throw HistoryQueryError.currentConversation }
        guard snapshot.past.contains(where: { $0.id == id }) else { throw HistoryQueryError.missingConversation }
        try Task.checkCancellation()
        try await store.deleteArchived(id)
    }

}
