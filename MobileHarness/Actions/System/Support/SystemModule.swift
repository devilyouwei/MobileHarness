import ActionRuntime

public struct SystemModule: CapabilityModule {
    public init() {}
    public var definitions: [ToolDefinition] {
        [SystemActions.runtimeInfoDefinition(handler: { try await SystemActions.runtimeInfo($0) })]
    }
}
