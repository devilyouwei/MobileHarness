import Foundation
import FunctionContracts
import Storage

public struct HistoryConversationReference: Sendable, Equatable {
    public let value: String
    public init(id: String) { value = id }
    public init(_ raw: String) throws {
        guard let id = BusinessRecordID(rawValue: raw), id.kind == .dialog else {
            throw ActionArguments.ValidationError.invalidValue("id")
        }
        value = id.rawValue
    }
}

public protocol HistoryQueryCapability: Sendable {
    func list(offset: Int, limit: Int) async throws -> String
    func read(reference: HistoryConversationReference, offset: Int, limit: Int) async throws -> String
}

public protocol HistoryMutationCapability: Sendable {
    func deleteArchived(_ id: String) async throws
    func startNew() async throws -> String?
    func summarizeArchived(_ id: String) async throws
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
