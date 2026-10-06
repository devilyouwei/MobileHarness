import Foundation

/// Bounded producer vocabulary shared by callable functions and protocol adapters.
public struct ActionExecutionFailureCode: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        precondition(!rawValue.isEmpty && rawValue.utf8.count <= 64)
        self.rawValue = rawValue
    }
    public static let invalidArguments = Self(rawValue: "invalidArguments")
    public static let handlerFailed = Self(rawValue: "handlerFailed")
    public static let timedOut = Self(rawValue: "timedOut")
    public static let cancelled = Self(rawValue: "cancelled")
    public static let permissionDenied = Self(rawValue: "permissionDenied")
    public static let resourceUnavailable = Self(rawValue: "resourceUnavailable")
    public static let deliveryFailed = Self(rawValue: "deliveryFailed")
}

/// Runtime reads producer codes without depending on business or device error types.
public protocol ActionExecutionFailureProviding: Error {
    var executionFailureCode: ActionExecutionFailureCode { get }
}

/// Host adaptation preserves the producer's reason with a generic code/message value.
public struct ActionExecutionFailure: LocalizedError, Sendable, ActionExecutionFailureProviding {
    public let executionFailureCode: ActionExecutionFailureCode
    public let errorDescription: String?
    public init(code: ActionExecutionFailureCode, message: String) {
        executionFailureCode = code
        errorDescription = String(message.prefix(512))
    }
}
