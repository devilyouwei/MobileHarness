import FunctionContracts

/// Task invocation admission only; the Agent owner supplies actual task orchestration.
@MainActor public final class TaskControlEndpoint: TaskControlCapability, TaskControlBinding {
    public typealias Handler =
        @Sendable (String, [String: String], String, String, String, String?) async throws -> ActionCompletion
    private let rootSessionID: String
    public var handler: Handler?
    public init(rootSessionID: String) { self.rootSessionID = rootSessionID }
    public func controlTask(_ operation: String, arguments: [String: String], invocation: any FunctionInput)
        async throws -> ActionCompletion
    {
        guard let handler else { throw ActionHostError.scopeClosed }
        if invocation.context.decisionID == nil, invocation.context.sessionID != rootSessionID {
            throw ActionHostError.scopeClosed
        }
        return try await handler(
            operation, arguments, invocation.context.source, invocation.context.sessionID,
            invocation.context.inputID, invocation.context.decisionID)
    }
}
