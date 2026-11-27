import Foundation

/// Business handlers see only this shared interface, never a call protocol or Channel.
public protocol FunctionInput: Sendable {
    var results: any FunctionReporting { get }
    var executionID: String { get }
    var executionOwner: ExecutionOwner? { get }
    var context: ActionExecutionContext { get }
    var call: FunctionRequest { get }
    var attachment: (any Sendable)? { get }
}
extension FunctionInput {
    public var attachment: (any Sendable)? { nil }
    public var executionOwner: ExecutionOwner? { nil }
}

public protocol FunctionReporting: Sendable {
    func record(_ report: ActionReport) async throws
    func snapshot() async -> ActionReport?
}
public struct FunctionInvocation: FunctionInput {
    public let results: any FunctionReporting
    public let executionID: String
    public let executionOwner: ExecutionOwner?
    public let roundID: String?
    public let context: ActionExecutionContext
    public let call: FunctionRequest
    public let attachment: (any Sendable)?
    public init(
        call: FunctionRequest, context: ActionExecutionContext, executionID: String,
        results: any FunctionReporting, attachment: (any Sendable)? = nil, executionOwner: ExecutionOwner? = nil,
        roundID: String? = nil
    ) {
        self.attachment = attachment
        self.call = call
        self.context = context
        self.executionID = executionID
        self.executionOwner = executionOwner
        self.roundID = roundID
        self.results = results
    }
}
public typealias ActionHandler = @Sendable (any FunctionInput) async throws -> Void
public typealias ActionValueHandler = @Sendable (any FunctionInput) async throws -> String
public typealias ActionCompletionHandler = @Sendable (any FunctionInput) async throws -> ActionCompletion
