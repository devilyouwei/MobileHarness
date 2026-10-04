import Foundation

public enum ActionStatus: String, Sendable { case succeeded, partialFailure, failed, cancelled }
public enum ActionCompletion: Equatable, Sendable {
    case completed
    case report(ActionReport)
    case activityStarted(UUID)
    case activityStopped(UUID)
}
/// Opaque producer failure identity. Runtime knows only generic execution failures.
public struct ActionFailure: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        precondition(!rawValue.isEmpty && rawValue.utf8.count <= 64)
        self.rawValue = rawValue
    }
    public static let operationFailed = Self(rawValue: "operationFailed")
    public static let resourceUnavailable = Self(rawValue: "resourceUnavailable")
    public static let invalidArguments = Self(rawValue: "invalidArguments")
}

public protocol ActionExecutionFailureProviding: Error {
    var actionExecutionFailure: ActionFailure { get }
    /// The producer translates domain failures; Runtime transports the supplied code.
    var actionReportCode: ActionReport.Entry.Code { get }
}
extension ActionExecutionFailureProviding {
    public var actionReportCode: ActionReport.Entry.Code {
        switch actionExecutionFailure {
        case .invalidArguments: .invalidArguments
        case .resourceUnavailable: .unavailable
        default: .handlerFailed
        }
    }
}
