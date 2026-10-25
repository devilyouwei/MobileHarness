import ExecutionRuntime
import FunctionContracts

/// Scheduled-call protocol facade; all execution belongs to FunctionExecutor.
public struct ActionExecutor: Sendable {
    private let registry: ActionRegistry
    public init(registry: ActionRegistry) { self.registry = registry }
    @discardableResult
    public func execute(_ invocation: any FunctionInput) async throws -> ActionCompletion {
        _ = try registry.definition(for: invocation.call.actionPath)
        return try await FunctionExecutor(registry: registry.functions).execute(invocation)
    }
    public static func perform(
        _ invocation: any FunctionInput, definition: ActionFunction
    ) async throws -> ActionCompletion {
        try await FunctionExecutor.perform(invocation, definition: definition)
    }
    public static func validate(completion: ActionCompletion, kind: ActionFunction.Kind) throws {
        try FunctionExecutor.validate(completion: completion, kind: kind)
    }
}
