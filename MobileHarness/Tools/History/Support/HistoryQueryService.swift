import Foundation
import StorageChat
import ToolRuntime

public enum HistoryQueryError: Error, Equatable, Sendable, ToolExecutionFailureProviding {
    case missingConversation, resultTooLarge, currentConversation
    public var toolFailureCode: ToolResponse.FailureCode {
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
        let id: UUID
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
            throw ToolArguments.ValidationError.invalidValue("pagination")
        }
        try Task.checkCancellation()
        let snapshot = try await store.snapshot()
        try Task.checkCancellation()
        let records = [snapshot.current] + snapshot.past
        let entries = records.dropFirst(offset).prefix(limit).map {
            Entry(
                id: $0.id, archived: $0.archivedAt != nil, createdAt: $0.createdAt, archivedAt: $0.archivedAt,
                summaryTitle: $0.summaryTitle.map { Text($0, maximumBytes: 40) },
                latestUser: $0.turns.last.map { Text($0.user, maximumBytes: 40) }, turnCount: $0.turns.count)
        }
        let next = offset + entries.count
        return try encode(Page(items: entries, total: records.count, nextOffset: next < records.count ? next : nil))
    }
    public func read(id: UUID, offset: Int, limit: Int) async throws -> String {
        guard (0...256).contains(offset), (1...2).contains(limit) else {
            throw ToolArguments.ValidationError.invalidValue("pagination")
        }
        try Task.checkCancellation()
        let snapshot = try await store.snapshot()
        try Task.checkCancellation()
        guard let record = ([snapshot.current] + snapshot.past).first(where: { $0.id == id }) else {
            throw HistoryQueryError.missingConversation
        }
        let turns = record.turns.dropFirst(offset).prefix(limit).map {
            Turn(
                id: $0.id, state: $0.state, user: Text($0.user, maximumBytes: 80),
                response: Text($0.raw, maximumBytes: 160))
        }
        let next = offset + turns.count
        return try encode(
            Page(items: turns, total: record.turns.count, nextOffset: next < record.turns.count ? next : nil))
    }
}
