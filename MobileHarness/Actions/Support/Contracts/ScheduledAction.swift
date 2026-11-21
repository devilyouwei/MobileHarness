import Foundation

/// Agent–Action invocation envelope (internal Signal). Scheduling correlation is independent of the producer's business protocol.
public struct ExecutionEnvelope: Sendable {
    public let invocationSnapshot: ActionInvocationSnapshot?
    public let source: String
    public let sessionID: String
    public let inputID: String
    public let schedulingID: String
    public let orderingScope: String?
    public let sequence: UInt64
    public let roundID: String?
    public let callID: String?
    public let context: ActionExecutionContext
    public let correlation: (any Sendable)?
    public init(
        source: String, sessionID: String, inputID: String, schedulingID: String,
        sequence: UInt64 = 0, roundID: String? = nil, callID: String? = nil,
        context: ActionExecutionContext, correlation: (any Sendable)? = nil, orderingScope: String? = nil,
        invocationSnapshot: ActionInvocationSnapshot? = nil
    ) {
        self.invocationSnapshot = invocationSnapshot
        self.orderingScope = orderingScope
        self.source = source
        self.sessionID = sessionID
        self.inputID = inputID
        self.schedulingID = schedulingID
        self.sequence = sequence
        self.roundID = roundID
        self.callID = callID
        self.context = context
        self.correlation = correlation
    }
}
/// Main-track scheduling events. pause stalls dispatch of later events for the owning input without waiting
/// for already dispatched Actions.
public enum ExecutionSchedulingDirective: Sendable, Equatable {
    case beginWait, endWait
    case pause(milliseconds: Int)
}

/// Agent → Action invocation (internal Signal) admitted through the Actions execution engine.
public struct ScheduledAction: Sendable {
    public let channel: String
    public let execution: FunctionInvocation
    public let executionID: String
    public let envelope: ExecutionEnvelope
    public var call: FunctionRequest { execution.call }
    public var results: any FunctionReporting { execution.results }
    public let owner: ExecutionOwner?
    public let feedback: ActionFeedback
    public let lease: ResourceLease?
    public let prepared: PreparedAction?
    public init(
        envelope: ExecutionEnvelope, call: FunctionRequest, channel: String,
        executionID: String = UUID().uuidString, owner: ExecutionOwner? = nil,
        feedback: ActionFeedback = .none, lease: ResourceLease? = nil, prepared: PreparedAction? = nil,
        results: (any FunctionReporting)? = nil
    ) throws {
        guard ActionIdentifier.validName(channel),
            owner.map({ $0.endpoint == envelope.source && $0.sessionID == envelope.sessionID })
                ?? (feedback == .none && lease == nil),
            lease.map({ $0.owner == owner }) ?? true
        else { throw ActionExecutionError.invalidInvocation }
        self.channel = channel
        self.executionID = executionID
        self.envelope = envelope
        self.owner = owner
        self.feedback = feedback
        self.lease = lease
        self.prepared = prepared
        self.execution = FunctionInvocation(
            call: call, context: envelope.context, executionID: executionID, results: results ?? ActionReportStore())
    }
    public func preparing(_ ticket: PreparedAction) throws -> Self {
        try Self(
            envelope: envelope, call: call, channel: channel, executionID: executionID,
            owner: owner, feedback: feedback, lease: lease, prepared: ticket, results: execution.results)
    }
}
