import FunctionContracts

@ActionCatalog
public struct HistoryModule: CapabilityModule {
    private let history: any HistoryQueryCapability
    private let mutations: any HistoryMutationCapability
    private let fullReads: (any HistoryFullReadCapability)?
    public init(
        history: any HistoryQueryCapability, mutations: any HistoryMutationCapability,
        fullReads: (any HistoryFullReadCapability)? = nil
    ) {
        self.fullReads = fullReads
        self.history = history
        self.mutations = mutations
    }
    public var definitions: [ActionFunction] {
        var values = [
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
        values.append(HistoryActions.fullReadFunction(using: fullReads ?? UnavailableHistoryRead()))
        return values
    }
}

private struct UnavailableHistoryRead: HistoryFullReadCapability {
    func read(_ query: HistoryReadQuery) throws -> HistoryReadResult { throw HistoryQueryError.unavailable }
}
