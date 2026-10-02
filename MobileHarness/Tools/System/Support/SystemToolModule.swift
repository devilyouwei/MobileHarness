import ToolRuntime

public struct SystemToolModule: ToolModule {
    public init() {}
    public var definitions: [ToolDefinition] {
        [SystemTools.runtimeInfoDefinition(handler: { try await SystemTools.runtimeInfo($0) })]
    }
}
