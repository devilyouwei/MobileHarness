import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import StorageChat
import StorageCore
import StorageTasks
import UI

extension WriterAgent {
    func execute(_ operation: String, args: [String: String] = [:], input: AgentInput) async throws -> String {
        guard let consumer else { throw WriterFailure.unavailable }
        let path = Self.workspacePath + operation
        let capabilities = descriptor.capabilities
        let call: ToolCall
        if let internalTool = capabilities.internalTools.first(where: { $0.path == path }) {
            call = try internalTool.call(args)
        } else {
            guard let alias = capabilities.tools.first(where: { $0.path == path })?.alias else {
                throw WriterFailure.invalidOutput
            }
            call = try capabilities.resolveTool(alias, arguments: args)
        }
        sequence += 1
        let output = OutputEnvelope(
            source: .writer, context: input.context, output: .toolCall(call), sequence: sequence,
            taskScope: input.taskScope)
        let result = try await consumer.callTool(output)
        if result.isCancellationOnly { throw CancellationError() }
        guard !result.isError, let response = result.tool else {
            var details = ["tool": path]
            details["command"] = operation == "publish" ? "finish" : operation
            details["path"] = args["path"]
            details["dispatchFailure"] = result.failureCode?.rawValue
            details["toolFailureCode"] = result.tool?.failureCode?.rawValue
            if result.failureCode != nil { details["repairable"] = "false" }
            let failure = result.failure ?? result.tool?.value ?? "Missing tool response"
            if operation == "read", failure == "missingFile", let scope = input.taskScope,
                let entry = workspaceContexts[scope.id]?.entry, args["path"] == entry
            {
                details["condition"] = "workspaceEntryMissing"
                throw WriterToolFailure(
                    try AgentPrompts.text("Writer/WorkspaceFeedback", "missingEntry", ["entry": entry]),
                    context: details)
            }
            throw WriterToolFailure(failure, context: details)
        }
        return response.value
    }
}
