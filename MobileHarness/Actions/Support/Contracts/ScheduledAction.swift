import Foundation

public enum CallScope: String, Codable, Sendable {
    case start, end
}

public enum ActionSchedulingScope: Hashable, Sendable {
    case round(String)
    case standaloneCall(String)
    case task(String)
    case input(String)
}

/// Agent–Action invocation envelope (internal Signal). Scheduling correlation is independent of the producer's business protocol.
public struct ExecutionEnvelope: Sendable {
    public let invocationSnapshot: ActionInvocationSnapshot?
    public let source: String
    public let sessionID: String
    public let inputID: String
    public let schedulingScope: ActionSchedulingScope
    public let orderingScope: String?
    public let sequence: UInt64
    private let associatedCallID: String?
    public var roundID: String? {
        if case .round(let id) = schedulingScope { return id }
        return nil
    }
    public var callID: String? {
        if case .standaloneCall(let id) = schedulingScope { return id }
        return associatedCallID
    }
    public let context: ActionExecutionContext
    public let correlation: (any Sendable)?
    public init(
        source: String, sessionID: String, inputID: String, schedulingScope: ActionSchedulingScope,
        sequence: UInt64 = 0, callID: String? = nil,
        context: ActionExecutionContext, correlation: (any Sendable)? = nil, orderingScope: String? = nil,
        invocationSnapshot: ActionInvocationSnapshot? = nil
    ) {
        self.invocationSnapshot = invocationSnapshot
        self.orderingScope = orderingScope
        self.source = source
        self.sessionID = sessionID
        self.inputID = inputID
        self.schedulingScope = schedulingScope
        self.sequence = sequence
        if case .standaloneCall = schedulingScope {
            self.associatedCallID = nil
        } else {
            self.associatedCallID = callID
        }
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
    public static let waitPath = ActionIdentifier(domain: "Scheduling", module: "Wait", function: "wait")
    public let scope: CallScope?
    public var isWait: Bool { call.actionPath == Self.waitPath }
    public let channel: String
    public let execution: FunctionInvocation
    public var executionID: String { execution.executionID }
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
        results: (any FunctionReporting)? = nil, scope: CallScope? = nil
    ) throws {
        guard ActionIdentifier.validName(channel),
            owner.map({ $0.endpoint == envelope.source && $0.sessionID == envelope.sessionID })
                ?? (feedback == .none && lease == nil),
            lease.map({ $0.owner == owner }) ?? true
        else { throw ActionExecutionError.invalidInvocation }
        self.scope = scope
        self.channel = channel
        self.envelope = envelope
        self.owner = owner
        self.feedback = feedback
        self.lease = lease
        self.prepared = prepared
        self.execution = FunctionInvocation(
            call: call, context: envelope.context, executionID: executionID, results: results ?? ActionReportStore(),
            executionOwner: owner)
    }
    public func preparing(_ ticket: PreparedAction) throws -> Self {
        try Self(
            envelope: envelope, call: call, channel: channel, executionID: executionID,
            owner: owner, feedback: feedback, lease: lease, prepared: ticket, results: execution.results, scope: scope)
    }
}
