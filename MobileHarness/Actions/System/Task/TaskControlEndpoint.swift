import AgentCore
import FunctionContracts

/// Task invocation admission only; the Agent owner supplies actual task orchestration.
@MainActor public final class TaskControlEndpoint: TaskControlCapability {
    public typealias Handler =
        @Sendable (String, [String: String], String, String, String, String?) async throws -> String
    private let rootSessionID: String
    public var handler: Handler?
    public init(rootSessionID: String) { self.rootSessionID = rootSessionID }
    public func controlTask(_ operation: String, arguments: [String: String], invocation: any FunctionInput)
        async throws -> String
    {
        guard let handler else { throw CommunicationError.scopeClosed }
        if invocation.context.decisionID == nil {
            guard invocation.context.source == "assistant", invocation.context.sessionID == rootSessionID else {
                throw CommunicationError.unauthorized
            }
        }
        return try await handler(
            operation, arguments, invocation.context.source, invocation.context.sessionID,
            invocation.context.inputID, invocation.context.decisionID)
    }
}
