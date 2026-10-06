import ActionRuntime
import Foundation

/// UI.HistoryPresentation function ownership; current invocation paths remain compatible.
extension UIActions {
    @Tool(path: "UI.HistoryPresentation.showHistory", title: "showHistory")
    public static func showHistory(invocation: ToolInvocation, using history: any HistoryPresentationCapability)
        async throws
    {
        try Task.checkCancellation()
        try ToolArguments(invocation.call.arguments).validateAllowedKeys([])
        try await history.showHistory(invocation: invocation)
        try Task.checkCancellation()
    }
}
