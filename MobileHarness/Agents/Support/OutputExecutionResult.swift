import AgentCore
import Foundation
import FunctionContracts
import Gateway

/// A single output outcome. Action terminal details remain in the scheduler's execution records.
public struct OutputExecutionResult: Sendable {
    public let invocation: ActionInvocationSnapshot?
    public let source: AgentID
    public let inputID: String
    public let sequence: UInt64
    public let tool: ToolResponse?
    public let failure: String?
    /// Dispatch/delivery failure is independent of the Tool handler failure code.
    public let failureCode: ActionExecutionFailureCode?
    public init(
        source: AgentID, inputID: String, sequence: UInt64, tool: ToolResponse?, failure: String?,
        failureCode: ActionExecutionFailureCode? = nil, invocation: ActionInvocationSnapshot? = nil
    ) {
        self.invocation = invocation
        self.source = source
        self.inputID = inputID
        self.sequence = sequence
        self.tool = tool
        self.failure = failure
        self.failureCode = failureCode
    }
    /// Convert the reply to the original Tool invocation into a local workflow input.
    func toolReplyInput(for envelope: OutputEnvelope) throws -> AgentInput {
        guard source == envelope.source, inputID == envelope.inputID, sequence == envelope.sequence,
            case .toolCall(let call) = envelope.output
        else { throw CommunicationError.invalidPayload }
        let reply: ToolResult
        if let failure {
            reply = ToolResult(callID: call.id, value: failure, isError: true, failureCode: failureCode?.rawValue)
        } else if let tool, tool.callID == call.id {
            reply = tool.agentResult(roundID: envelope.roundID, invocation: invocation)
        } else {
            throw CommunicationError.invalidPayload
        }
        return try envelope.toolFeedbackInput(reply)
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
