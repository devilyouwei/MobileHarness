import Foundation
import FunctionContracts
import Storage
import StorageChat

public enum HistoryQueryError: Error, Equatable, Sendable, ActionExecutionFailureProviding {
    case missingConversation, resultTooLarge, currentConversation
    public var executionFailureCode: ActionExecutionFailureCode {
        switch self {
        case .currentConversation: .invalidArguments
        case .missingConversation: .init(rawValue: "notFound")
        case .resultTooLarge: .init(rawValue: "resultTooLarge")
        }
    }
}

/// Read-only business projection. No new store, queue, title inference or effect replay.
public struct HistoryQueryService: HistoryQueryCapability {
    private let store: ConversationHistoryStore
    public init(store: ConversationHistoryStore) { self.store = store }

    private struct Text: Encodable {
        let value: String
        let truncated: Bool
        init(_ raw: String, maximumBytes: Int) {
            var prefix = ""
            for character in raw {
                guard prefix.utf8.count + String(character).utf8.count <= maximumBytes else { break }
                prefix.append(character)
            }
            value = prefix
            truncated = prefix != raw
        }
    }
    private struct Entry: Encodable {
        let id: String
        let archived: Bool
        let createdAt: Date
        let archivedAt: Date?
        let summaryTitle: Text?
        let latestUser: Text?
        let turnCount: Int
    }
    private struct Turn: Encodable {
        let id: String
        let state: ConversationRecord.State
        let kind: String
        let taskID: String?
        let inputID: String?
        let user: Text
        let response: Text
    }
    private struct Page<Item: Encodable>: Encodable {
        let items: [Item]
        let total: Int
        let nextOffset: Int?
    }
    private func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 1800 else { throw HistoryQueryError.resultTooLarge }
        return String(decoding: data, as: UTF8.self)
    }
    public func list(offset: Int, limit: Int) async throws -> String {
        guard (0...64).contains(offset), (1...5).contains(limit) else {
            throw ActionArguments.ValidationError.invalidValue("pagination")
        }
        try Task.checkCancellation()
        let records = try await store.listConversations()
        try Task.checkCancellation()
        let entries = records.dropFirst(offset).prefix(limit).map {
            return Entry(
                id: $0.id,
                archived: $0.archivedAt != nil, createdAt: $0.createdAt, archivedAt: $0.archivedAt,
                summaryTitle: $0.summaryTitle.map { Text($0, maximumBytes: 40) },
                latestUser: ($0.latestUser ?? $0.turns.last?.user).map { Text($0, maximumBytes: 40) },
                turnCount: $0.turnCount ?? $0.turns.count)
        }
        let next = offset + entries.count
        return try encode(Page(items: entries, total: records.count, nextOffset: next < records.count ? next : nil))
    }
    public func read(reference: HistoryConversationReference, offset: Int, limit: Int) async throws -> String {
        guard (0...1_000_000).contains(offset), (1...2).contains(limit) else {
            throw ActionArguments.ValidationError.invalidValue("pagination")
        }
        try Task.checkCancellation()
        guard let id = BusinessRecordID(rawValue: reference.value), id.kind == .dialog else {
            throw ActionArguments.ValidationError.invalidValue("id")
        }
        try Task.checkCancellation()
        let page: (items: [ConversationHistoryItem], total: Int)
        do {
            page = try await store.timelinePage(id.rawValue, offset: offset, limit: limit)
        } catch ConversationHistoryError.missingTurn { throw HistoryQueryError.missingConversation }
        let items = page.items
        let turns = items.map { item -> Turn in
            switch item {
            case .request(let input, let request):
                return Turn(
                    id: request.messageID ?? request.id, state: request.state, kind: "request",
                    taskID: request.historyTaskID,
                    inputID: input.messageID ?? input.id,
                    user: Text(request.input, maximumBytes: 80),
                    response: Text(request.response, maximumBytes: 160))
            case .task(let compression):
                let text = [compression.reportedSummary, compression.failure].compactMap { $0 }.joined(separator: "\n")
                return Turn(
                    id: compression.taskID, state: compression.status, kind: "task", taskID: compression.taskID,
                    inputID: nil,
                    user: Text(compression.goal, maximumBytes: 80), response: Text(text, maximumBytes: 160))
            }
        }
        let next = offset + turns.count
        return try encode(Page(items: turns, total: page.total, nextOffset: next < page.total ? next : nil))
    }
}
