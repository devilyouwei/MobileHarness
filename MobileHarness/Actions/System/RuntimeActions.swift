import FunctionContracts

/// System.Runtime function ownership; current invocation paths remain compatible.
extension SystemActions {
    @Action(
        domain: "System", module: "Runtime", title: "runtimeInfo", serializationKey: "System")
    public static func runtimeInfo(_ invocation: any FunctionInput) async throws -> String {
        "本地聊天与语音能力已配置"
    }
}
