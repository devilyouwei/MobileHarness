public struct SystemToolModule: ToolModule {
    public init() {}
    public var definitions: [ToolDefinition] {
        [ToolDefinition(path: "runtimeInfo", handler: { try await SystemTools.runtimeInfo($0) })]
    }
}
