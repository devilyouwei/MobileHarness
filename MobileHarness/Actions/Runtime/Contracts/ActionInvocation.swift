import Foundation

public struct ActionInvocation: Sendable {
    public let results = ActionReportStore()
    public let executionID: UUID
    public let context: ActionExecutionContext
    public let call: ActionRequest
    public init(call: ActionRequest, context: ActionExecutionContext, executionID: UUID = UUID()) {
        self.call = call
        self.context = context
        self.executionID = executionID
    }
}
public typealias ActionHandler = @Sendable (ActionInvocation) async throws -> Void
public typealias ActionCompletionHandler = @Sendable (ActionInvocation) async throws -> ActionCompletion
