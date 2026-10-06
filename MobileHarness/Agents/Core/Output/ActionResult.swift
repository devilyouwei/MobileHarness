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

public struct ActionResult: Sendable, Equatable {
    public enum Status: String, Sendable { case succeeded, partialFailure, failed, cancelled }
    public enum Effect: String, Sendable { case notStarted, contractCompleted, unknown }
    public enum Failure: String, Sendable { case handlerFailed, cancelled, resourceUnavailable }

    public let executionID: UUID
    public let owner: ExecutionOwner
    public let inputID: UUID
    public let turn: AgentTurn?
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
        executionID: UUID, owner: ExecutionOwner, inputID: UUID, turn: AgentTurn?, path: ActionPath,
        status: Status, effect: Effect, completion: AgentActionCompletion? = nil, failure: Failure? = nil
    ) {
        self.executionID = executionID
        self.owner = owner
        self.inputID = inputID
        self.turn = turn
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
    public let owner: ExecutionOwner
    public let state: State
    public let sequence: UInt64

    public init(activityID: UUID, owner: ExecutionOwner, state: State, sequence: UInt64) {
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
