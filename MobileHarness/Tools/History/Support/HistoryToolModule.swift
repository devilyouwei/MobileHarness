import Foundation
import ToolRuntime

public protocol HistoryQueryCapability: Sendable {
    func list(offset: Int, limit: Int) async throws -> String
    func read(id: UUID, offset: Int, limit: Int) async throws -> String
}

public protocol HistoryMutationCapability: Sendable {
    func deleteArchived(_ id: UUID) async throws
}

public struct HistoryToolModule: ToolModule {
    private let history: any HistoryQueryCapability
    private let mutations: any HistoryMutationCapability
    public init(history: any HistoryQueryCapability, mutations: any HistoryMutationCapability) {
        self.history = history
        self.mutations = mutations
    }
    public var definitions: [ToolDefinition] {
        [
            HistoryTools.deleteDefinition(handler: { [mutations] call in
                try await HistoryTools.delete(call: call, using: mutations)
            }),
            HistoryTools.listDefinition(handler: { [history] call in
                try await HistoryTools.list(call: call, using: history)
            }),
            HistoryTools.readDefinition(handler: { [history] call in
                try await HistoryTools.read(call: call, using: history)
            }),
        ]
    }
}
