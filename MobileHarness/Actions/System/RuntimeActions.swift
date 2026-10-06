import ActionRuntime

/// System.Runtime function ownership; current invocation paths remain compatible.
extension SystemActions {
    @Tool(path: "System.Runtime.runtimeInfo", title: "runtimeInfo")
    public static func runtimeInfo(_ call: ToolRequest) async throws -> String {
        "本地聊天与语音能力已配置"
    }
}
