import Foundation
import FunctionContracts

public struct ActionsFailure: Error, Sendable {
    public enum Code: String, Sendable {
        case unavailable, stopped, conflict, capacityExceeded, executionFailed, cleanupFailed
    }
    public let code: Code
    public let operation: String
    public let underlying: any Error
    public let cleanupErrors: [any Error]
    public var isCancellation: Bool { underlying is CancellationError && cleanupErrors.isEmpty }
    public init(
        operation: String, underlying: any Error, cleanupErrors: [any Error] = [], code: Code = .executionFailed
    ) {
        self.code = code
        self.operation = operation
        self.underlying = underlying
        self.cleanupErrors = cleanupErrors
    }
}
public enum ActionsContainerError: Error, Sendable {
    case unavailable, alreadyConfigured, stopped, capacityExceeded, invalidPreparation, missingBinding
}
