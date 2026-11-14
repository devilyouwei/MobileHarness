import FunctionContracts

/// System.Runtime function ownership; current invocation paths remain compatible.
extension SystemActions {
    @Action(
        domain: "System", module: "Runtime", title: "runtimeInfo")
    public static func runtimeInfo(_ invocation: any FunctionInput) async throws -> String {
        "Local chat and speech capabilities are configured"
    }
}
