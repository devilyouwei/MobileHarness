import Foundation

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

extension ToolResponse {
    public static func response(
        _ completion: ActionCompletion, policy: ActionExecutionDescriptor.DirectResultPolicy,
        callID: String
    ) throws -> ToolResponse? {
        let value: String
        var isError = false
        switch completion {
        case .completed: value = "completed"
        case .value(let returned): value = returned
        case .activityStarted(let id): value = "activityStarted:\(id)"
        case .activityStopped(let id): value = "activityStopped:\(id)"
        case .report(let report):
            isError = report.hasFailures || report.isCancelled
            let object: [String: Any] = [
                "entries": report.entries.map { entry -> [String: Any] in
                    var value: [String: Any] = [
                        "path": entry.path, "status": entry.status.rawValue, "details": entry.details,
                    ]
                    if let code = entry.code { value["code"] = code.rawValue }
                    return value
                }, "executionFailure": report.executionFailure?.rawValue ?? NSNull(),
                "failureDescription": report.failureDescription ?? NSNull(),
            ]
            value = String(
                decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        guard policy == .returning || isError else { return nil }
        return ToolResponse(
            callID: callID, value: value, isError: isError, failureCode: failureCode(completion, isError: isError),
            completion: completion)
    }

    public static func failureCode(_ completion: ActionCompletion, isError: Bool) -> ActionExecutionFailureCode? {
        guard isError else { return nil }
        if case .report(let report) = completion {
            if report.executionFailure == .timedOut { return .timedOut }
            if report.isCancellationOnly { return .cancelled }
            if let code = report.executionFailure
                ?? report.entries.first(where: { $0.status == .failed && $0.code != .cancelled })?.code
            {
                return .init(rawValue: code.rawValue)
            }
        }
        return .handlerFailed
    }

}
