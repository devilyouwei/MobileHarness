import Foundation

public struct ExecutionStart: Sendable {
    public let executionID: String
    public let owner: ExecutionOwner
    public let envelope: ExecutionEnvelope
    public let path: ActionIdentifier?
    public let controlCapabilities: Set<String>
    public init(
        executionID: String, owner: ExecutionOwner, envelope: ExecutionEnvelope,
        path: ActionIdentifier? = nil, controlCapabilities: Set<String> = []
    ) {
        self.executionID = executionID
        self.path = path
        self.controlCapabilities = controlCapabilities
        self.owner = owner
        self.envelope = envelope
    }
}

/// Action → Agent terminal fact (internal Signal feedback), redelivered by the result ledger without re-executing.
public struct ExecutionResult: Sendable {
    public enum Status: String, Sendable { case succeeded, partialFailure, failed, cancelled }
    public enum Effect: String, Sendable { case notStarted, contractCompleted, unknown }
    public enum Failure: String, Sendable { case handlerFailed, cancelled, resourceUnavailable }
    public let invocation: ActionInvocationSnapshot?
    public let executionID: String
    public let owner: ExecutionOwner
    public let path: ActionIdentifier
    public let envelope: ExecutionEnvelope
    public let status: Status
    public let effect: Effect
    public let completion: ActionCompletion?
    public let failure: Failure?
    public init(
        executionID: String, owner: ExecutionOwner, path: ActionIdentifier, envelope: ExecutionEnvelope,
        status: Status, effect: Effect, completion: ActionCompletion?, failure: Failure?,
        invocation: ActionInvocationSnapshot? = nil
    ) {
        self.executionID = executionID
        self.owner = owner
        self.path = path
        self.envelope = envelope
        self.status = status
        self.effect = effect
        self.completion = completion
        self.failure = failure
        self.invocation = invocation
    }
    public var roundID: String? { envelope.roundID }
}

public struct ToolExecutionResult: Sendable {
    public let executionID: String
    public let owner: ExecutionOwner
    public let inputID: String
    public let roundID: String?
    public let outcome: Result<ActionCompletion, any Error>
}

/// Terminal execution payload sent to the original caller independently of call acknowledgment.
public enum CallResultSignal: Sendable {
    public static let contract = "execution.call.result.v1"
    public static let channel = "execution.call.result"
    case action(ExecutionResult)
    case tool(ToolExecutionResult)

    public var executionID: String {
        switch self {
        case .action(let result): result.executionID
        case .tool(let result): result.executionID
        }
    }

    public var owner: ExecutionOwner {
        switch self {
        case .action(let result): result.owner
        case .tool(let result): result.owner
        }
    }
}

/// Execution lifecycle notifications, independent of terminal call results and control acknowledgments.
public enum ActionExecutionEventSignal: Sendable {
    public static let contract = "action.execution.event.v1"
    public static let channel = "action.execution.event"
    case started(ExecutionStart)
    case control(ActionControlFeedback)

    public var executionID: String {
        switch self {
        case .started(let event): return event.executionID
        case .control(let event):
            switch event.event {
            case .stateChanged(let change): return change.executionID
            case .receipt(let receipt): return receipt.executionID
            }
        }
    }

    public var owner: ExecutionOwner {
        switch self {
        case .started(let event): event.owner
        case .control(let event): event.owner
        }
    }
}

extension ActionStatus {
    public var executionResultStatus: ExecutionResult.Status {
        switch self {
        case .succeeded: .succeeded
        case .partialFailure: .partialFailure
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}
