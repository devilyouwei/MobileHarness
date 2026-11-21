import Foundation
import FunctionContracts

/// UI.HistoryPresentation function ownership; current invocation paths remain compatible.
extension UIActions {
    @Action(
        domain: "UI", module: "HistoryPresentation", title: "showHistory",
        doc: "Present the conversation history list in the app UI.", timeout: .seconds(5))
    public static func showHistory(invocation: any FunctionInput, using history: any HistoryPresentationCapability)
        async throws
    {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await history.showHistory(invocation: invocation)
        try Task.checkCancellation()
    }
}
