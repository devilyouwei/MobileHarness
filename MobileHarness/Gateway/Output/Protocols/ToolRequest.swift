import ExecutionRuntime
import Foundation
import FunctionContracts

public struct ToolRequest: Equatable, Sendable {
    public let id: UUID
    public let toolPath: String
    public let arguments: [String: String]
    public init(id: UUID = UUID(), toolPath: String, arguments: [String: String] = [:]) {
        self.id = id
        self.toolPath = toolPath
        self.arguments = arguments
    }
}

/// Native wire adapter; business handlers receive only the normalized invocation.

extension FunctionInvocation {
    public init(tool: ToolRequest, context: ActionExecutionContext) {
        let parts = tool.toolPath.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let address =
            parts.count == 3
            ? ActionIdentifier(domain: parts[0], module: parts[1], function: parts[2])
            : ActionIdentifier(domain: "", module: "", function: tool.toolPath)
        self.init(
            call: .init(actionPath: address, parameters: tool.arguments),
            context: context,
            executionID: tool.id, results: ActionReportStore())
    }
}

extension ActionInvocation {
    public init(tool: ToolRequest, context: ActionExecutionContext) {
        let input = FunctionInvocation(tool: tool, context: context)
        self.init(
            call: .init(actionPath: input.call.actionPath, channel: "", parameters: input.call.parameters),
            context: context, executionID: tool.id)
    }
}
