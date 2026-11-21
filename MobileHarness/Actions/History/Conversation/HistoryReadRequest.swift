import Foundation
import FunctionContracts
import StorageChat
import UI

public enum HistoryReadQuery: Sendable {
    case conversation(String)
    case message(String)
    case page(id: String, after: UInt64, taskID: String?)
    case archives(before: Int64)

    public func validate() throws {
        let ids: [String]
        switch self {
        case .conversation(let id), .message(let id): ids = [id]
        case .page(let id, _, let taskID): ids = [id] + (taskID.map { [$0] } ?? [])
        case .archives: ids = []
        }
        guard ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw HistoryQueryError.missingConversation
        }
    }
}

public enum HistoryReadResult: Sendable {
    case conversation(AssistantConversation)
    case archives([AssistantConversation])

    public func validate() throws {
        switch self {
        case .conversation(let value):
            guard try JSONEncoder().encode(value).count <= AssistantHistoryStore.maximumBytes else {
                throw HistoryQueryError.resultTooLarge
            }
        case .archives(let values):
            guard values.count <= 20, try JSONEncoder().encode(values).count <= AssistantHistoryStore.maximumBytes
            else { throw HistoryQueryError.resultTooLarge }
        }
    }
}

public typealias HistoryReadInvocation = ActionRequestSlot<HistoryInput, HistoryReply>

public protocol HistoryFullReadCapability: Sendable {
    func read(_ query: HistoryReadQuery) async throws -> HistoryReadResult
}
