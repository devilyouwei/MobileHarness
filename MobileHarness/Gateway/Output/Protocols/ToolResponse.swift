import ExecutionRuntime
import Foundation
import FunctionContracts

public struct ToolResponse: Equatable, Sendable {
    public typealias FailureCode = ActionExecutionFailureCode
    public let completion: ActionCompletion?
    public let failureCode: FailureCode?
    public let callID: String
    public let value: String
    public let isError: Bool
    /// Feedback transport failure is independent of the handler outcome.
    public let deliveryFailure: String?
    public init(
        callID: String, value: String, isError: Bool = false, deliveryFailure: String? = nil,
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

// Native adapter vocabulary; business producers use only protocol-neutral execution codes.
extension ActionExecutionFailureCode {
    public static let unknownTool = Self(rawValue: "unknownTool")
}
