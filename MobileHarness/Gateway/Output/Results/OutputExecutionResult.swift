import ActionRuntime
import AgentCore
import Foundation

/// A single output outcome. Action terminal details remain in the scheduler's execution records.
public struct OutputExecutionResult: Sendable {
    public let source: AgentID
    public let inputID: UUID
    public let sequence: UInt64
    public let tool: ToolResponse?
    public let failure: String?
    /// Dispatch/delivery failure is independent of the Tool handler failure code.
    public let failureCode: ToolResponse.FailureCode?
    public init(
        source: AgentID, inputID: UUID, sequence: UInt64, tool: ToolResponse?, failure: String?,
        failureCode: ToolResponse.FailureCode? = nil
    ) {
        self.source = source
        self.inputID = inputID
        self.sequence = sequence
        self.tool = tool
        self.failure = failure
        self.failureCode = failureCode
    }
    public var isError: Bool { failure != nil || tool?.isError == true }
}

public struct OutputExecutionSnapshot: Sendable {
    public let outputs: [OutputExecutionResult]
    public let actions: ActionExecutionSnapshot
    public let evictedOutputs: UInt64
}
