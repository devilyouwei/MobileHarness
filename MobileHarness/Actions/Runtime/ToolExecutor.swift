import Foundation

/// Direct execution with a cooperative deadline; cleanup joins before returning an outcome.
public struct ToolExecutor: Sendable {
    private let registry: ToolRegistry
    public static let defaultTimeout: Duration = .seconds(30)
    private let timeout: Duration
    public enum ConfigurationError: Error { case invalidTimeout }
    public init(registry: ToolRegistry) {
        self.registry = registry
        self.timeout = Self.defaultTimeout
    }
    public init(registry: ToolRegistry, timeout: Duration) throws {
        guard timeout > .zero && timeout <= .seconds(300) else { throw ConfigurationError.invalidTimeout }
        self.registry = registry
        self.timeout = timeout
    }
    public func execute(_ call: ToolRequest, context: ToolExecutionContext) async throws -> ToolResponse? {
        try Task.checkCancellation()
        guard let definition = await registry.handler(for: call.toolPath) else {
            return ToolResponse(
                callID: call.id, value: "Unknown tool: \(call.toolPath)",
                isError: true, failureCode: .unknownTool)
        }
        do {
            let completion = try await ActionExecutor.perform(
                ActionInvocation(tool: call, context: context),
                definition: definition, defaultTimeout: timeout)
            try Task.checkCancellation()
            return try Self.response(completion, policy: definition.directResultPolicy, callID: call.id)
        } catch {
            try Task.checkCancellation()
            return ToolResponse(
                callID: call.id, value: ActionReport.description(for: error), isError: true,
                failureCode: error is CancellationError
                    ? .cancelled
                    : (error as? any ToolExecutionFailureProviding)?.toolFailureCode ?? .handlerFailed)
        }
    }
    public static func response(
        _ completion: ActionCompletion, policy: ActionDefinition.DirectResultPolicy,
        callID: UUID
    ) throws -> ToolResponse? {
        let value: String
        var isError = false
        switch completion {
        case .completed: value = "completed"
        case .value(let returned): value = returned
        case .activityStarted(let id): value = "activityStarted:\(id.uuidString)"
        case .activityStopped(let id): value = "activityStopped:\(id.uuidString)"
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

    private static func failureCode(_ completion: ActionCompletion, isError: Bool) -> ToolResponse.FailureCode? {
        guard isError else { return nil }
        if case .report(let report) = completion {
            if report.executionFailure == .timedOut { return .timedOut }
            if report.isCancelled { return .cancelled }
        }
        return .handlerFailed
    }

}
