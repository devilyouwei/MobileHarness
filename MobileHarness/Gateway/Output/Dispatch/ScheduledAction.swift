import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts

public struct ScheduledAction: Sendable {
    public var channel: String { call.channel }
    public var results: any FunctionReporting { execution.results }
    public let execution: ActionInvocation
    public let executionID: UUID
    public let envelope: OutputEnvelope
    public let call: ActionCall
    public let owner: ExecutionOwner?
    public let feedback: ActionFeedback
    public let lease: ResourceLease?

    /// The envelope is the single source of call identity; non-Action outputs cannot be invoked.
    public init(
        envelope: OutputEnvelope, owner: ExecutionOwner? = nil,
        feedback: ActionFeedback = .none, lease: ResourceLease? = nil
    ) throws {
        try self.init(
            envelope: envelope, owner: owner, feedback: feedback, lease: lease, context: envelope.executionContext)
    }
    /// Trusted Gateway-only projection may retain the parent's handler context in a child scope.
    init(
        envelope: OutputEnvelope, owner: ExecutionOwner?, feedback: ActionFeedback = .none,
        lease: ResourceLease?, context: ActionExecutionContext
    ) throws {
        guard case .actionCall(let call) = envelope.output else { throw ActionExecutionError.invalidInvocation }
        guard
            owner.map({ $0.agent == envelope.source && $0.sessionID == envelope.sessionID })
                ?? (feedback == .none && lease == nil),
            lease.map({ $0.owner == owner }) ?? true
        else { throw ActionExecutionError.invalidInvocation }
        self.owner = owner
        self.feedback = feedback
        self.lease = lease
        self.executionID = UUID()
        self.execution = ActionInvocation(
            call: call.executionRequest, context: context, executionID: self.executionID)
        self.envelope = envelope
        self.call = call
    }

    public init(source: AgentID, input: AgentInput, call: ActionCall, sequence: UInt64 = 0) {
        let envelope = OutputEnvelope(source: source, input: input, output: .actionCall(call), sequence: sequence)
        self.owner = nil
        self.feedback = .none
        self.lease = nil
        self.executionID = UUID()
        self.envelope = envelope
        self.call = call
        self.execution = ActionInvocation(
            call: call.executionRequest, context: envelope.executionContext, executionID: self.executionID)
    }
}
