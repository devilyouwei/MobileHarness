import Foundation

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
