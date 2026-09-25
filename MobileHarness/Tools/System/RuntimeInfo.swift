import AgentCore

public enum SystemTools {
    public static func runtimeInfo(_ call: ToolCall) async throws -> String {
        "本地聊天与语音能力已配置"
    }
}
