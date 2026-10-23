import Foundation
import FunctionContracts
import StorageChat

public enum HistoryReadQuery: Sendable {
    case conversation(String)
    case message(String)
    case page(id: String, after: UInt64, taskID: String?)
    case archives(before: Int64)
    case photo(id: String, inputID: String)

    public func validate() throws {
        let ids: [String]
        switch self {
        case .conversation(let id), .message(let id): ids = [id]
        case .page(let id, _, let taskID): ids = [id] + (taskID.map { [$0] } ?? [])
        case .archives: ids = []
        case .photo(let id, let inputID): ids = [id, inputID]
        }
        guard ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw HistoryQueryError.missingConversation
        }
    }
}

public enum HistoryReadResult: Sendable {
    case conversation(StoredConversation)
    case archives([StoredConversation])
    case photo(Data?)

    public func validate() throws {
        switch self {
        case .conversation(let value):
            guard try JSONEncoder().encode(value).count <= ConversationHistoryStore.maximumBytes else {
                throw HistoryQueryError.resultTooLarge
            }
        case .archives(let values):
            guard values.count <= 20, try JSONEncoder().encode(values).count <= ConversationHistoryStore.maximumBytes
            else { throw HistoryQueryError.resultTooLarge }
        case .photo(let data):
            guard (data?.count ?? 0) <= 4 * 1024 * 1024 else { throw HistoryQueryError.resultTooLarge }
        }
    }
}

/// One request-owned result slot, never a global staging table or input queue.
public actor HistoryReadInvocation {
    public let query: HistoryReadQuery
    public let requestID: String
    public let sessionID: String
    private var result: HistoryReadResult?
    private var closed = false
    private var admitted = false
    private var failure: (any Error)?
    public init(query: HistoryReadQuery, requestID: String, sessionID: String) throws {
        try query.validate()
        self.query = query
        self.requestID = requestID
        self.sessionID = sessionID
    }
    public func accept(_ invocation: any FunctionInput) throws {
        guard !closed, !admitted, invocation.context.source == "memory",
            invocation.context.sessionID == sessionID, invocation.context.inputID == requestID,
            invocation.context.taskID == nil
        else { throw HistoryQueryError.missingConversation }
        admitted = true
    }
    public func complete(_ value: HistoryReadResult) throws {
        try Task.checkCancellation()
        try value.validate()
        guard !closed, admitted, result == nil else { throw HistoryQueryError.missingConversation }
        result = value
    }
    public func take() throws -> HistoryReadResult {
        try Task.checkCancellation()
        guard !closed, let result else { throw HistoryQueryError.missingConversation }
        self.result = nil
        closed = true
        return result
    }
    public func fail(_ error: any Error) { if !closed { failure = error } }
    public func throwFailure() throws { if let failure { throw failure } }
    public func close() {
        closed = true
        result = nil
        failure = nil
    }
}

public protocol HistoryFullReadCapability: Sendable {
    func read(_ query: HistoryReadQuery) async throws -> HistoryReadResult
}
