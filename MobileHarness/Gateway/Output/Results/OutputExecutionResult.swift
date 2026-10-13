import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts

/// A single output outcome. Action terminal details remain in the scheduler's execution records.
public struct OutputExecutionResult: Sendable {
    public let source: AgentID
    public let inputID: UUID
    public let sequence: UInt64
    public let tool: ToolResponse?
    public let failure: String?
    /// Dispatch/delivery failure is independent of the Tool handler failure code.
    public let failureCode: ActionExecutionFailureCode?
    public init(
        source: AgentID, inputID: UUID, sequence: UInt64, tool: ToolResponse?, failure: String?,
        failureCode: ActionExecutionFailureCode? = nil
    ) {
        self.source = source
        self.inputID = inputID
        self.sequence = sequence
        self.tool = tool
        self.failure = failure
        self.failureCode = failureCode
    }
    public var isError: Bool { !isCancellationOnly && (failure != nil || tool?.isError == true) }

    /// Cancellation remains an unsuccessful outcome, but is not itself a runtime incident.
    public var isCancellationOnly: Bool {
        guard failure == nil || failureCode == .cancelled,
            failureCode == nil || failureCode == .cancelled,
            tool?.deliveryFailure == nil,
            tool?.failureCode == nil || tool?.failureCode == .cancelled
        else { return false }
        if case .report(let report) = tool?.completion {
            guard report.executionFailure == nil || report.executionFailure == .cancelled,
                !report.entries.contains(where: { $0.status == .failed && $0.code != .cancelled })
            else { return false }
            return report.isCancelled || failureCode == .cancelled || tool?.failureCode == .cancelled
        }
        return failureCode == .cancelled || tool?.failureCode == .cancelled
    }
}

public struct OutputExecutionSnapshot: Sendable {
    public let outputs: [OutputExecutionResult]
    public let actions: ActionExecutionSnapshot
    public let evictedOutputs: UInt64
}
