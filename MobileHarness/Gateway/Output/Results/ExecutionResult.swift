import Foundation
import FunctionContracts

public struct ExecutionResult: Sendable {
    public enum Status: String, Sendable { case succeeded, partialFailure, failed, cancelled }
    public enum Effect: String, Sendable { case notStarted, contractCompleted, unknown }
    public enum Failure: String, Sendable { case handlerFailed, cancelled, resourceUnavailable }
    public let executionID: String
    public let owner: ExecutionOwner
    public let path: ActionIdentifier
    public let envelope: ExecutionEnvelope
    public let status: Status
    public let effect: Effect
    public let completion: ActionCompletion?
    public let failure: Failure?
    public var roundID: String? { envelope.roundID }
}

extension ActionStatus {
    var executionResultStatus: ExecutionResult.Status {
        switch self {
        case .succeeded: .succeeded
        case .partialFailure: .partialFailure
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}
