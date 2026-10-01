public enum SystemTools {
    @Tool(path: "runtimeInfo", title: "runtimeInfo")
    public static func runtimeInfo(_ call: ToolRequest) async throws -> String {
        "本地聊天与语音能力已配置"
    }
}
