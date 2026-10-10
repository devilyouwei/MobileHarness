import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts

extension ActionCall {
    public var executionRequest: ActionRequest {
        .init(
            actionPath: .init(domain: actionPath.domain, module: actionPath.module, function: actionPath.function),
            channel: channel,
            parameters: parameters)
    }
}
extension OutputEnvelope {
    public var executionContext: ActionExecutionContext {
        .init(
            source: source.rawValue, sessionID: sessionID, inputID: inputID, sequence: sequence,
            correlationID: turn?.id, ordinal: turn?.ordinal, decisionID: roundID, taskID: taskScope?.id,
            taskExecutor: taskScope?.executor.rawValue)
    }

}
extension ActionRegistry {
    public func definition(for path: ActionPath) throws -> ActionBinding {
        try definition(for: ActionIdentifier(domain: path.domain, module: path.module, function: path.function))
    }
    public func validate(capabilities: CapabilityRegistry) throws {
        for action in capabilities.actions { _ = try definition(for: action.path) }
        for action in capabilities.internalActions { _ = try definition(for: action.path) }
    }
}
extension ActionBinding {
    public func requiredResources(for call: ActionCall) throws -> Set<ResourceID> {
        Set(try requiredResources(for: call.executionRequest.functionRequest).map { ResourceID(rawValue: $0.rawValue) })
    }
}
extension ActionCompletion {
    var agentValue: AgentActionCompletion {
        switch self {
        case .completed: .completed
        case .value(let value): .value(value)
        case .activityStarted(let id): .activityStarted(id)
        case .activityStopped(let id): .activityStopped(id)
        case .report(let report): .report(report.agentValue)
        }
    }
}
extension ActionReport {
    public var agentValue: AgentActionReport {
        // The Action contract has already validated the same bounds as the delivery contract.
        AgentActionReport(
            delivering: entries.map {
                .init(
                    path: $0.path, status: $0.status.agentValue, code: $0.code?.agentValue, details: $0.details)
            }, executionFailure: executionFailure?.agentValue, failureDescription: failureDescription)
    }
}
extension ActionFailure {
    var observationFailure: ActionExecutionRecord.Failure {
        .init(rawValue: rawValue)
    }
}
extension ToolCall {
    public var executionRequest: ToolRequest { .init(id: id, toolPath: toolPath, arguments: arguments) }
}

extension ActionReport.Entry.Status {
    var agentValue: AgentActionReport.Entry.Status {
        switch self {
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        case .notStarted: .notStarted
        }
    }
}

extension ActionReport.Entry.Code {
    var agentValue: AgentActionReport.Entry.Code {
        .init(rawValue: rawValue)
    }
}

extension ActionStatus {
    var agentValue: ActionResult.Status {
        switch self {
        case .succeeded: .succeeded
        case .partialFailure: .partialFailure
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}
