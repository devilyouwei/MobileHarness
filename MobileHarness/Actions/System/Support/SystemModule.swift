import FunctionContracts

public struct SystemModule: CapabilityModule {
    public init() {}
    public var definitions: [ActionFunction] {
        [SystemActions.runtimeInfoDefinition(completing: { .value(try await SystemActions.runtimeInfo($0)) })]
    }
}
