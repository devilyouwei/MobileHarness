import ActionRuntime
import Foundation

public protocol HistoryQueryCapability: Sendable {
    func list(offset: Int, limit: Int) async throws -> String
    func read(id: UUID, offset: Int, limit: Int) async throws -> String
}

public protocol HistoryMutationCapability: Sendable {
    func deleteArchived(_ id: UUID) async throws
}

public struct HistoryModule: CapabilityModule {
    private let history: any HistoryQueryCapability
    private let mutations: any HistoryMutationCapability
    public init(history: any HistoryQueryCapability, mutations: any HistoryMutationCapability) {
        self.history = history
        self.mutations = mutations
    }
    public var definitions: [ToolDefinition] {
        [
            HistoryActions.deleteDefinition(handler: { [mutations] call in
                try await HistoryActions.delete(call: call, using: mutations)
            }),
            HistoryActions.listDefinition(handler: { [history] call in
                try await HistoryActions.list(call: call, using: history)
            }),
            HistoryActions.readDefinition(handler: { [history] call in
                try await HistoryActions.read(call: call, using: history)
            }),
        ]
    }
}
