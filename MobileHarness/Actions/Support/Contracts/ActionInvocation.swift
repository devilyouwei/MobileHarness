import Foundation

/// Scheduling adapter; business handlers can access only FunctionInput requirements.
public struct ActionInvocation: FunctionInput {
    public let results: any FunctionReporting
    public let executionID: String
    public let context: ActionExecutionContext
    public let call: FunctionRequest
    public let channel: String
    public init(call: ActionRequest, context: ActionExecutionContext, executionID: String) {
        self.call = call.functionRequest
        self.channel = call.channel
        self.context = context
        self.executionID = executionID
        self.results = ActionReportStore()
    }
}
