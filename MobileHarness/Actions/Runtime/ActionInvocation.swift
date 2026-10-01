import AgentCore
import Foundation

public struct ActionInvocation: Sendable {
    public let results = ActionReportStore()
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
        self.envelope = envelope
        self.call = call
    }

    /// Convenience for trusted composition/tests; creates the envelope from the same call.
    public init(source: AgentID, input: AgentInput, call: ActionCall, sequence: UInt64 = 0) {
        self.owner = nil
        self.feedback = .none
        self.lease = nil
        self.executionID = UUID()
        self.envelope = OutputEnvelope(source: source, input: input, output: .actionCall(call), sequence: sequence)
        self.call = call
    }
}

public typealias ActionHandler = @Sendable (ActionInvocation) async throws -> Void

public typealias ActionCompletionHandler = @Sendable (ActionInvocation) async throws -> ActionCompletion

/// Compatibility name for Action domain argument decoding.
public typealias ActionArguments = CallArguments

public actor ActionReportStore {
    private var report: ActionReport?
    public init() {}
    public func record(_ report: ActionReport) throws {
        guard self.report == nil else { throw ActionExecutionError.invalidCompletion }
        self.report = report
    }
    public func snapshot() -> ActionReport? { report }
}
