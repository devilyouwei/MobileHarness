import AgentCore

public struct ActionExecutor: Sendable {
    private let registry: ActionRegistry
    public init(registry: ActionRegistry) { self.registry = registry }
    @discardableResult
    public func execute(_ invocation: ActionInvocation) async throws -> ActionCompletion {
        try Task.checkCancellation()
        let definition = try registry.definition(for: invocation.call.actionPath)
        let handler = definition.handler
        let completion = try await handler(invocation)
        try Task.checkCancellation()
        switch (definition.kind, completion) {
        case (.activityStart, .activityStarted), (.activityStop, .activityStopped),
            (.finite, .completed), (.state, .completed), (.activityUpdate, .completed):
            break
        default: throw ActionExecutionError.invalidCompletion
        }
        return completion
    }
}
