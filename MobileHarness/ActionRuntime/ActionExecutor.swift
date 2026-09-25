import AgentCore

public struct ActionExecutor: Sendable {
    private let registry: ActionRegistry
    public init(registry: ActionRegistry) { self.registry = registry }
    public func execute(_ invocation: ActionInvocation) async throws {
        try Task.checkCancellation()
        let handler = try registry.handler(for: invocation.call.actionPath)
        try await handler(invocation)
        try Task.checkCancellation()
    }
}
