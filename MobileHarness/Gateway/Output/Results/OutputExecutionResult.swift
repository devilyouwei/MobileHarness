import AgentCore
import Foundation
import ToolRuntime

/// A single output outcome. Action terminal details remain in the scheduler's execution records.
public struct OutputExecutionResult: Sendable {
    public let source: AgentID
    public let inputID: UUID
    public let sequence: UInt64
    public let tool: ToolResponse?
    public let failure: String?
    public var isError: Bool { failure != nil || tool?.isError == true }
}

public struct OutputExecutionSnapshot: Sendable {
    public let outputs: [OutputExecutionResult]
    public let actions: ActionExecutionSnapshot
    public let evictedOutputs: UInt64
}
