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
            if !completion.hasExecutionFailure { try Task.checkCancellation() }
            return try Self.response(
                completion,
                policy: returning ? .returning : definition.directResultPolicy, callID: call.id)
        } catch {
            let report = ActionReport.failureReport(for: error)
            if !report.hasFailures { try Task.checkCancellation() }
            let completion = ActionCompletion.report(report)
            return ToolResponse(
                callID: call.id, value: report.failureDescription ?? ActionReport.description(for: error),
                isError: true, failureCode: Self.failureCode(completion, isError: true), completion: completion)
        }
    }
    public static func response(
        _ completion: ActionCompletion, policy: ActionBinding.DirectResultPolicy, callID: String
    ) throws -> ToolResponse? {
        try ToolResponse.response(completion, policy: policy, callID: callID)
    }
    private static func failureCode(_ completion: ActionCompletion, isError: Bool) -> ActionExecutionFailureCode? {
        ToolResponse.failureCode(completion, isError: isError)
    }
}
