import Foundation

public struct ActionInvocation: Sendable {
    public let results = ActionReportStore()
    public let executionID: UUID
    public let context: ActionExecutionContext
    public let call: ActionRequest
    public init(call: ActionRequest, context: ActionExecutionContext, executionID: UUID = UUID()) {
        self.call = call
        self.context = context
        self.executionID = executionID
    }
}
public typealias ActionHandler = @Sendable (ActionInvocation) async throws -> Void
public typealias ActionCompletionHandler = @Sendable (ActionInvocation) async throws -> ActionCompletion

extension ActionInvocation {
    /// Adapter view; the canonical handler never depends on a scheduler or Agent.
    public var toolInvocation: ToolInvocation {
        ToolInvocation(
            call: .init(id: executionID, toolPath: call.actionPath.description, arguments: call.parameters),
            context: .init(
                source: context.source, sessionID: context.sessionID, inputID: context.inputID,
                sequence: context.sequence, correlationID: context.correlationID, ordinal: context.ordinal))
    }
    public init(tool: ToolRequest, context: ToolExecutionContext) {
        let parts = tool.toolPath.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let address =
            parts.count == 3
            ? ActionIdentifier(domain: parts[0], module: parts[1], function: parts[2])
            : ActionIdentifier(domain: "", module: "", function: tool.toolPath)
        self.init(
            call: .init(actionPath: address, channel: "", parameters: tool.arguments),
            context: .init(
                source: context.source, sessionID: context.sessionID, inputID: context.inputID,
                sequence: context.sequence, correlationID: context.correlationID, ordinal: context.ordinal),
            executionID: tool.id)
    }
}
