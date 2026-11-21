import Foundation
import FunctionContracts
import StorageChat

public struct HistoryFullReadService: HistoryFullReadCapability {
    private let store: AssistantHistoryStore
    public init(store: AssistantHistoryStore) { self.store = store }
    public func read(_ query: HistoryReadQuery) async throws -> HistoryReadResult {
        try query.validate()
        try Task.checkCancellation()
        switch query {
        case .conversation(let id): return .conversation(try await store.page(id))
        case .message(let id): return .conversation(try await store.message(id))
        case .page(let id, let after, let taskID):
            return .conversation(try await store.page(id, after: after, taskID: taskID))
        case .archives(let before): return .archives(try await store.archivePage(before: before))
        }
    }
}
