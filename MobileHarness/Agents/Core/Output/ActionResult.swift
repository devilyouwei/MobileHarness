import Foundation

/// Trusted runtime ownership, captured before admission rather than supplied by model parameters.
public struct ExecutionOwner: Hashable, Sendable {
    public let agent: AgentID
    public let incarnation: UUID
    public let sessionID: UUID

    public init(agent: AgentID, incarnation: UUID, sessionID: UUID) {
        self.agent = agent
        self.incarnation = incarnation
        self.sessionID = sessionID
    }
}

public enum ActionFeedback: Sendable { case none, failuresOnly, terminal }

public enum AgentActionCompletion: Equatable, Sendable {
    case completed
    case value(String)
    case report(AgentActionReport)
    case activityStarted(UUID)
    case activityStopped(UUID)
}

/// Causal identity only; retaining feedback never retains the initiating media or service lifetime.
public struct SignalCausality: Sendable, Equatable {
    public let inputID: UUID
    public let rootID: UUID
    public let hops: Int
    public let turn: AgentTurn?
    public let sequence: UInt64
    public init(inputID: UUID, rootID: UUID, hops: Int, turn: AgentTurn? = nil, sequence: UInt64 = 0) {
        self.inputID = inputID
        self.rootID = rootID
        self.hops = hops
        self.turn = turn
        self.sequence = sequence
    }
    public init(envelope: OutputEnvelope) {
        self.init(
            inputID: envelope.inputID, rootID: envelope.inputMetadata.rootID,
            hops: envelope.inputMetadata.hops, turn: envelope.turn, sequence: envelope.sequence)
    }
    /// Explicit host activity root when no Agent input exists.
    public static func root(id: UUID = UUID()) -> Self {
        .init(inputID: id, rootID: id, hops: 0)
    }
}

public struct ActionResult: Sendable, Equatable {
    public enum Status: String, Sendable { case succeeded, partialFailure, failed, cancelled }
    public enum Effect: String, Sendable { case notStarted, contractCompleted, unknown }
    public enum Failure: String, Sendable { case handlerFailed, cancelled, resourceUnavailable }

    public let callID: UUID?
    public let roundID: UUID?
    public let executionID: UUID
    public let owner: ExecutionOwner
    public let causality: SignalCausality
    public var inputID: UUID { causality.inputID }
    public var turn: AgentTurn? { causality.turn }
    public let path: ActionPath
    public let status: Status
    public let effect: Effect
    public let completion: AgentActionCompletion?
    public let failure: Failure?
    public var report: AgentActionReport? {
        if case .report(let report) = completion { return report }
        return nil
    }

    public init(
        executionID: UUID, owner: ExecutionOwner, path: ActionPath, causality: SignalCausality,
        status: Status, effect: Effect, completion: AgentActionCompletion? = nil, failure: Failure? = nil,
        callID: UUID? = nil, roundID: UUID? = nil
    ) {
        self.callID = callID
        self.roundID = roundID
        self.executionID = executionID
        self.owner = owner
        self.causality = causality
        self.path = path
        self.status = status
        self.effect = effect
        self.completion = completion
        self.failure = failure
    }
}

public struct ActivityEvent: Sendable, Equatable {
    public enum State: String, Sendable { case started, stopped, failed, revoked }
    public let activityID: UUID
    public let causality: SignalCausality
    public let owner: ExecutionOwner
    public let state: State
    public let sequence: UInt64

    public init(activityID: UUID, owner: ExecutionOwner, state: State, sequence: UInt64, causality: SignalCausality) {
        self.causality = causality
        self.activityID = activityID
        self.owner = owner
        self.state = state
        self.sequence = sequence
    }
}

/// Input admission is distinct from the physical effect and from business consumption.
public enum ActionResultDelivery: Sendable {
    case accepted
    case retry
    case closed
}
