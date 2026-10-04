import ActionRuntime
import AgentCore
import Foundation
import ToolRuntime

extension ActionCall {
    public var executionRequest: ActionRequest {
        .init(
            actionPath: .init(module: actionPath.module, function: actionPath.function), channel: channel,
            parameters: parameters)
    }
}
extension OutputEnvelope {
    public var executionContext: ActionExecutionContext {
        .init(
            source: source.rawValue, sessionID: sessionID, inputID: inputID, sequence: sequence,
            correlationID: turn?.id, ordinal: turn?.ordinal)
    }
    public var toolContext: ToolExecutionContext {
        .init(
            source: source.rawValue, sessionID: sessionID, inputID: inputID, sequence: sequence,
            correlationID: turn?.id, ordinal: turn?.ordinal)
    }
}
extension ActionRegistry {
    public func definition(for path: ActionPath) throws -> ActionDefinition {
        try definition(for: ActionIdentifier(module: path.module, function: path.function))
    }
    public func validate(capabilities: CapabilityRegistry) throws {
        for action in capabilities.actions { _ = try definition(for: action.path) }
        for action in capabilities.internalActions { _ = try definition(for: action.path) }
    }
}
extension ActionDefinition {
    public func requiredResources(for call: ActionCall) throws -> Set<ResourceID> {
        Set(try requiredResources(for: call.executionRequest).map { ResourceID(rawValue: $0.rawValue) })
    }
}
extension ActionCompletion {
    var agentValue: AgentActionCompletion {
        switch self {
        case .completed: .completed
        case .activityStarted(let id): .activityStarted(id)
        case .activityStopped(let id): .activityStopped(id)
        case .report(let report): .report(report.agentValue)
        }
    }
}
extension ActionReport {
    var agentValue: AgentActionReport {
        // The Action contract has already validated the same bounds as the delivery contract.
        AgentActionReport(
            delivering: entries.map {
                .init(
                    path: $0.path, status: $0.status.agentValue, code: $0.code?.agentValue, details: $0.details)
            }, executionFailure: executionFailure?.agentValue)
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
