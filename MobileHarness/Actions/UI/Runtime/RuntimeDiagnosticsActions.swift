import FunctionContracts

extension UIActions {
    @Action(domain: "UI", module: "RuntimeDiagnostics", title: "recordFailure", timeout: .seconds(5))
    public static func recordFailure(
        invocation: any FunctionInput, using presentation: any RuntimeFailurePresentationCapability
    ) async throws {
        try Task.checkCancellation()
        let issue = try RuntimeIssue(parameters: invocation.call.parameters)
        try await presentation.recordRuntimeFailure(issue, invocation: invocation)
    }

}
