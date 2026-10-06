import Foundation

public struct ToolResponse: Equatable, Sendable {
    /// Generic execution vocabulary; concrete producers may supply their own bounded identifier.
    public struct FailureCode: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) {
            precondition(!rawValue.isEmpty && rawValue.utf8.count <= 64)
            self.rawValue = rawValue
        }
        public static let invalidArguments = Self(rawValue: "invalidArguments")
        public static let handlerFailed = Self(rawValue: "handlerFailed")
        public static let timedOut = Self(rawValue: "timedOut")
        public static let cancelled = Self(rawValue: "cancelled")
        public static let unknownTool = Self(rawValue: "unknownTool")
        public static let permissionDenied = Self(rawValue: "permissionDenied")
        public static let resourceUnavailable = Self(rawValue: "resourceUnavailable")
        public static let deliveryFailed = Self(rawValue: "deliveryFailed")
    }
    public let completion: ActionCompletion?
    public let failureCode: FailureCode?
    public let callID: UUID
    public let value: String
    public let isError: Bool
    /// Feedback transport failure is independent of the handler outcome.
    public let deliveryFailure: String?
    public init(
        callID: UUID, value: String, isError: Bool = false, deliveryFailure: String? = nil,
        failureCode: FailureCode? = nil, completion: ActionCompletion? = nil
    ) {
        self.completion = completion
        self.failureCode = isError ? (failureCode ?? .handlerFailed) : nil
        self.callID = callID
        self.value = value
        self.isError = isError
        self.deliveryFailure = deliveryFailure.map { String($0.prefix(512)) }
    }
}

/// Runtime reads producer codes without depending on business or device error types.
public protocol ToolExecutionFailureProviding: Error {
    var toolFailureCode: ToolResponse.FailureCode { get }
}

/// Host adaptation preserves the producer's reason with a generic code/message value.
public struct ToolExecutionFailure: LocalizedError, Sendable, ToolExecutionFailureProviding {
    public let toolFailureCode: ToolResponse.FailureCode
    public let errorDescription: String?
    public init(code: ToolResponse.FailureCode, message: String) {
        toolFailureCode = code
        errorDescription = String(message.prefix(512))
    }
}
