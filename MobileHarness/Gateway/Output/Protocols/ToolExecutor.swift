import ExecutionRuntime
import Foundation
import FunctionContracts

/// Direct execution with a cooperative deadline; cleanup joins before returning an outcome.
public struct ToolExecutor: Sendable {
    private let registry: ToolRegistry
    public init(registry: ToolRegistry) { self.registry = registry }
    public func execute(
        _ call: ToolRequest, context: ActionExecutionContext, returning: Bool = false, attachment: (any Sendable)? = nil
    ) async throws
        -> ToolResponse?
    {
        try Task.checkCancellation()
        guard let definition = await registry.handler(for: call.toolPath) else {
            return ToolResponse(
                callID: call.id, value: "Unknown tool: \(call.toolPath)",
                isError: true, failureCode: .unknownTool)
        }
        do {
            let completion = try await FunctionExecutor.perform(
                FunctionInvocation(tool: call, context: context, attachment: attachment),
                definition: definition.function)
            try Task.checkCancellation()
            return try Self.response(
                completion,
                policy: returning ? .returning : definition.directResultPolicy, callID: call.id)
        } catch {
            try Task.checkCancellation()
            let report = FunctionExecutor.failureReport(for: error)
            let completion = ActionCompletion.report(report)
            return ToolResponse(
                callID: call.id, value: report.failureDescription ?? ActionReport.description(for: error),
                isError: true, failureCode: Self.failureCode(completion, isError: true), completion: completion)
        }
    }
    public static func response(
        _ completion: ActionCompletion, policy: ActionBinding.DirectResultPolicy,
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
        if case .value = completion, value.utf8.count > 65_536 { throw ActionExecutionError.invalidCompletion }
        guard policy == .returning || isError else { return nil }
        return ToolResponse(
            callID: callID, value: value, isError: isError, failureCode: failureCode(completion, isError: isError),
            completion: completion)
    }

    private static func failureCode(_ completion: ActionCompletion, isError: Bool) -> ActionExecutionFailureCode? {
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
