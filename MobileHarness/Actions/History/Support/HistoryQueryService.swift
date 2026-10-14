import Foundation
import FunctionContracts
import StorageChat

public enum HistoryQueryError: Error, Equatable, Sendable, ActionExecutionFailureProviding {
    case missingConversation, resultTooLarge, currentConversation, ambiguousConversationReference
    public var executionFailureCode: ActionExecutionFailureCode {
        switch self {
        case .currentConversation, .ambiguousConversationReference: .invalidArguments
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
        let id: UUID
        let ref: String?
        let archived: Bool
        let createdAt: Date
        let archivedAt: Date?
        let summaryTitle: Text?
        let latestUser: Text?
        let turnCount: Int
    }
    private struct Turn: Encodable {
        let id: UUID
        let state: ConversationRecord.State
        let kind: String
        let taskID: UUID?
        let inputID: UUID?
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
        let counts = Dictionary(grouping: records, by: { String($0.id.uuidString.prefix(8)) }).mapValues(\.count)
        let entries = records.dropFirst(offset).prefix(limit).map {
            let ref = String($0.id.uuidString.prefix(8))
            return Entry(
                id: $0.id, ref: counts[ref] == 1 ? ref : nil,
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
        let id: UUID
        if let exact = UUID(uuidString: reference.value) {
            id = exact
        } else {
            let matches = try await store.listConversations().filter {
                String($0.id.uuidString.prefix(8)) == reference.value
            }
            guard !matches.isEmpty else { throw HistoryQueryError.missingConversation }
            guard matches.count == 1 else { throw HistoryQueryError.ambiguousConversationReference }
            id = matches[0].id
        }
        try Task.checkCancellation()
        let record: StoredConversation
        do { record = try await store.conversation(id) } catch ConversationHistoryError.missingTurn {
            throw HistoryQueryError.missingConversation
        }
        try Task.checkCancellation()
        let items = try record.indexedHistory()
        let turns = items.dropFirst(offset).prefix(limit).map { item -> Turn in
            switch item {
            case .request(let input, let request):
                return Turn(
                    id: request.id, state: request.state, kind: "request", taskID: request.historyTaskID,
                    inputID: input.id,
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
        return try encode(Page(items: turns, total: items.count, nextOffset: next < items.count ? next : nil))
    }
}
