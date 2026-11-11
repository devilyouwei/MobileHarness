import AgentCore
import Foundation
import FunctionContracts
import Gateway

extension OutputEnvelope {
    public var schedulingEnvelope: ExecutionEnvelope {
        .init(
            source: source.rawValue, sessionID: sessionID, inputID: inputID, schedulingID: schedulingID,
            sequence: sequence, roundID: roundID, callID: callID, context: executionContext,
            correlation: SignalCausality(envelope: self), orderingScope: source == .assistant ? "conversation" : nil)
    }
    public var actionObservation: ActionOutputObservation {
        let kind: ActionOutputObservation.Kind
        switch output {
        case .control(let value): kind = .control(value)
        case .toolCall(let call): kind = .tool(call.toolPath)
        default: kind = .other
        }
        return .init(kind: kind, source: source.rawValue, inputID: inputID)
    }
}
extension ExecutionResult {
    public var agentValue: ActionResult {
        ActionResult(
            executionID: executionID, owner: owner,
            path: .init(domain: path.domain, module: path.module, function: path.function),
            causality: (envelope.correlation as? SignalCausality)
                ?? .init(inputID: envelope.inputID, rootID: envelope.inputID, hops: 0),
            status: status.agentValue, effect: effect.agentValue, completion: completion?.agentValue,
            failure: failure?.agentValue, callID: envelope.callID, roundID: envelope.roundID)
    }
}
extension ExecutionResult.Status {
    var agentValue: ActionResult.Status {
        switch self {
        case .succeeded: .succeeded
        case .partialFailure: .partialFailure
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}
extension ExecutionResult.Effect {
    var agentValue: ActionResult.Effect {
        switch self {
        case .notStarted: .notStarted
        case .contractCompleted: .contractCompleted
        case .unknown: .unknown
        }
    }
}
extension ExecutionResult.Failure {
    var agentValue: ActionResult.Failure {
        switch self {
        case .handlerFailed: .handlerFailed
        case .cancelled: .cancelled
        case .resourceUnavailable: .resourceUnavailable
        }
    }
}
extension ScheduledAction {
    public init(
        envelope: OutputEnvelope, owner: ExecutionOwner? = nil, feedback: ActionFeedback = .none,
        lease: ResourceLease? = nil
    ) throws {
        guard case .actionCall(let call) = envelope.output else { throw ActionExecutionError.invalidInvocation }
        try self.init(
            envelope: envelope.schedulingEnvelope, call: call.executionRequest.functionRequest,
            channel: call.channel, owner: owner, feedback: feedback, lease: lease)
    }

}
extension ChannelScheduler {
    public func finish(inputID: String, source: AgentID) async throws {
        try await finish(inputID: inputID, source: source.rawValue)
    }
    public func cancel(inputID: String, source: AgentID) async {
        await cancel(inputID: inputID, source: source.rawValue)
    }
    public func cancel(agent: AgentID, incarnation: String, sessionID: String? = nil) async {
        await cancel(endpoint: agent.rawValue, incarnation: incarnation, sessionID: sessionID)
    }
    public func schedule(_ directive: SchedulingDirective, envelope: OutputEnvelope) throws {
        try schedule(directive == .beginWait ? .beginWait : .endWait, envelope: envelope.schedulingEnvelope)
    }
    public nonisolated func requiredResources(for call: ActionCall) async throws -> Set<ResourceID> {
        try await requiredResources(for: call.executionRequest.functionRequest)
    }
}
extension ResourceCoordinator {
    public func close(agent: AgentID, incarnation: String) async {
        await close(endpoint: agent.rawValue, incarnation: incarnation)
    }
}
extension ResourceDefinition {
    public init(
        id: ResourceID, allowedOwners: Set<AgentID>, requiresLease: Bool = false,
        executionGroup: ResourceID? = nil, preempts: [AgentID: Set<AgentID>] = [:],
        stop: @escaping @Sendable () async throws -> Void
    ) {
        self.init(
            id: id, allowedOwners: Set(allowedOwners.map(\.rawValue)), requiresLease: requiresLease,
            executionGroup: executionGroup,
            preempts: Dictionary(
                uniqueKeysWithValues: preempts.map { ($0.key.rawValue, Set($0.value.map(\.rawValue))) }), stop: stop)
    }
}

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
            taskExecutor: taskScope?.executor.rawValue, resourceBindings: resourceBindings)
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
