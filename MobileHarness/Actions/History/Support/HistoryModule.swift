import Foundation
import FunctionContracts

public struct HistoryConversationReference: Sendable, Equatable {
    public let value: String
    public init(id: UUID) { value = id.uuidString }
    public init(_ raw: String) throws {
        if let id = UUID(uuidString: raw) {
            value = id.uuidString
        } else {
            guard raw.utf8.count == 8,
                raw.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
            else { throw ActionArguments.ValidationError.invalidValue("id") }
            value = raw.uppercased()
        }
    }
}

public protocol HistoryQueryCapability: Sendable {
    func list(offset: Int, limit: Int) async throws -> String
    func read(reference: HistoryConversationReference, offset: Int, limit: Int) async throws -> String
}

public protocol HistoryMutationCapability: Sendable {
    func deleteArchived(_ id: UUID) async throws
    func startNew() async throws -> UUID?
    func summarizeArchived(_ id: UUID) async throws
}

@ActionCatalog
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
