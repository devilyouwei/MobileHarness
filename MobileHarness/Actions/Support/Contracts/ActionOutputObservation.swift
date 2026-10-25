import Foundation

public struct ActionOutputObservation: Sendable {
    public enum Kind: Sendable {
        case control(String)
        case tool(String)
        case other
    }
    public let kind: Kind
    public let source: String
    public let inputID: String
    public init(kind: Kind, source: String, inputID: String) {
        self.kind = kind
        self.source = source
        self.inputID = inputID
    }
}
public struct DeferredActionFailure: Sendable {
    public let executionID: String
    public let owner: ExecutionOwner
    public let path: ActionIdentifier
    public let context: ActionExecutionContext
    public let report: ActionReport?
    public init(
        executionID: String, owner: ExecutionOwner, path: ActionIdentifier,
        context: ActionExecutionContext, report: ActionReport?
    ) {
        self.executionID = executionID
        self.owner = owner
        self.path = path
        self.context = context
        self.report = report
    }
}
