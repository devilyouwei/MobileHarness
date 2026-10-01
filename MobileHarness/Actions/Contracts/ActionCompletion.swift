import Foundation

public enum ActionStatus: String, Sendable { case succeeded, partialFailure, failed, cancelled }
public enum ActionCompletion: Equatable, Sendable {
    case completed
    case report(ActionReport)
    case activityStarted(UUID)
    case activityStopped(UUID)
}
public enum ActionFailure: String, Sendable {
    case operationFailed, resourceUnavailable, disconnected, busy, background, invalidPose
    case unconfirmed, controlNotReady, feedbackTimeout, completionTimeout, invalidArguments
}
public protocol ActionExecutionFailureProviding: Error { var actionExecutionFailure: ActionFailure { get } }
