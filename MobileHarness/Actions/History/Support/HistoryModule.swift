import Foundation
import FunctionContracts

public protocol HistoryQueryCapability: Sendable {
    func list(offset: Int, limit: Int) async throws -> String
    func read(id: UUID, offset: Int, limit: Int) async throws -> String
}

public protocol HistoryMutationCapability: Sendable {
    func deleteArchived(_ id: UUID) async throws
    func startNew() async throws -> UUID?
    func summarizeArchived(_ id: UUID) async throws
}

public struct HistoryModule: CapabilityModule {
    private let history: any HistoryQueryCapability
    private let mutations: any HistoryMutationCapability
    public init(history: any HistoryQueryCapability, mutations: any HistoryMutationCapability) {
        self.history = history
        self.mutations = mutations
    }
    public var definitions: [ActionFunction] {
        [
            HistoryActions.startNewDefinition(completing: { [mutations] invocation in
                .value(try await HistoryActions.startNew(invocation: invocation, using: mutations))
            }),
            HistoryActions.summarizeDefinition(completing: { [mutations] invocation in
                .value(try await HistoryActions.summarize(invocation: invocation, using: mutations))
            }),
            HistoryActions.deleteDefinition(completing: { [mutations] invocation in
                .value(try await HistoryActions.delete(invocation: invocation, using: mutations))
            }),
            HistoryActions.listDefinition(completing: { [history] invocation in
                .value(try await HistoryActions.list(invocation: invocation, using: history))
            }),
            HistoryActions.readDefinition(completing: { [history] invocation in
                .value(try await HistoryActions.read(invocation: invocation, using: history))
            }),
        ]
    }
}
