import Foundation

/// Trusted runtime ownership, captured before admission rather than supplied by model parameters.
public struct ExecutionOwner: Codable, Hashable, Sendable {
    public let agent: AgentID
    public let incarnation: String
    public let sessionID: String

    public init(agent: AgentID, incarnation: String, sessionID: String) {
        self.agent = agent
        self.incarnation = incarnation
        self.sessionID = sessionID
    }
}

public enum ActionFeedback: Sendable { case none, failuresOnly, terminal }

public enum AgentActionCompletion: Codable, Equatable, Sendable {
    case completed
    case value(String)
    case report(AgentActionReport)
    case activityStarted(String)
    case activityStopped(String)

    /// Business output is distinct from terminal acknowledgment and execution-ledger identity.
    public var hasBusinessOutput: Bool {
        switch self {
        case .value: true
        case .completed, .report, .activityStarted, .activityStopped: false
        }
    }
}

/// Causal identity only; retaining feedback never retains the initiating media or service lifetime.
public struct SignalCausality: Codable, Sendable, Equatable {
    public let inputID: String
    public let rootID: String
    public let hops: Int
    public let turn: AgentTurn?
    public let sequence: UInt64
    public let taskScope: AgentTaskScope?
    public init(
        inputID: String, rootID: String, hops: Int, turn: AgentTurn? = nil, sequence: UInt64 = 0,
        taskScope: AgentTaskScope? = nil
    ) {
        self.inputID = inputID
        self.taskScope = taskScope
        self.rootID = rootID
        self.hops = hops
        self.turn = turn
        self.sequence = sequence
    }
    public init(envelope: OutputEnvelope) {
        self.init(
            inputID: envelope.inputID, rootID: envelope.inputMetadata.rootID,
            hops: envelope.inputMetadata.hops, turn: envelope.turn, sequence: envelope.sequence,
            taskScope: envelope.taskScope)
    }
    /// Explicit host activity root when no Agent input exists.
    public static func root(id: String = UUID().uuidString) -> Self {
        .init(inputID: id, rootID: id, hops: 0)
    }
}

public struct ActionResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case succeeded, partialFailure, failed, cancelled }
    public enum Effect: String, Codable, Sendable { case notStarted, contractCompleted, unknown }
    public enum Failure: String, Codable, Sendable { case handlerFailed, cancelled, resourceUnavailable }

    public let callID: String?
    public let roundID: String?
    public let executionID: String
    public let owner: ExecutionOwner
    public let causality: SignalCausality
    public var inputID: String { causality.inputID }
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
        executionID: String, owner: ExecutionOwner, path: ActionPath, causality: SignalCausality,
        status: Status, effect: Effect, completion: AgentActionCompletion? = nil, failure: Failure? = nil,
        callID: String? = nil, roundID: String? = nil
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
    public enum State: String, Codable, Sendable { case started, stopped, failed, revoked }
    public let activityID: String
    public let causality: SignalCausality
    public let owner: ExecutionOwner
    public let state: State
    public let sequence: UInt64

    public init(activityID: String, owner: ExecutionOwner, state: State, sequence: UInt64, causality: SignalCausality) {
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
