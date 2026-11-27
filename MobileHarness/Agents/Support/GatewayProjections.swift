import AgentCore
import Foundation
import FunctionContracts
import Gateway

extension OutputEnvelope {
    func toolFeedbackInput(_ result: ToolResult) throws -> AgentInput {
        guard (0..<8).contains(inputMetadata.hops) else { throw CommunicationError.hopLimitExceeded }
        let payload = InputPayload.toolResult(result)
        return AgentInput(
            id: UUID().uuidString, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "runtime", origin: .runtime, sequence: sequence,
                rootID: inputMetadata.rootID, parentID: inputID, hops: inputMetadata.hops + 1),
            turn: turn, taskScope: taskScope)
    }
    public var schedulingEnvelope: ExecutionEnvelope {
        .init(
            source: source.rawValue, sessionID: sessionID, inputID: inputID, schedulingScope: schedulingScope,
            sequence: sequence, callID: callID, context: executionContext,
            correlation: SignalCausality(envelope: self), orderingScope: source == .assistant ? "conversation" : nil,
            invocationSnapshot: invocation)
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
    var causality: SignalCausality {
        (envelope.correlation as? SignalCausality) ?? .root(id: envelope.inputID)
    }

    public var agentValue: ActionResult {
        ActionResult(
            executionID: executionID, owner: owner,
            path: .init(domain: path.domain, module: path.module, function: path.function),
            causality: causality,
            status: status.agentValue, effect: effect.agentValue, completion: completion?.agentValue,
            failure: failure?.agentValue, callID: envelope.callID, roundID: envelope.roundID,
            invocation: envelope.invocationSnapshot ?? invocation)
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
            channel: call.channel, owner: owner, feedback: feedback, lease: lease, scope: call.scope)
    }

}
extension ActionExecutionEngine {
    public func finish(scope: ActionSchedulingScope, source: AgentID) async throws {
        try await finish(scope: scope, source: source.rawValue)
    }
    public func cancel(scope: ActionSchedulingScope, source: AgentID) async {
        await cancel(scope: scope, source: source.rawValue)
    }
    @discardableResult public func cancel(agent: AgentID, incarnation: String, sessionID: String? = nil) async -> Bool {
        await cancel(endpoint: agent.rawValue, incarnation: incarnation, sessionID: sessionID)
    }
    public func schedule(
        _ directive: SchedulingDirective, envelope: OutputEnvelope, owner: ExecutionOwner? = nil
    ) async throws {
        let projected: ExecutionSchedulingDirective =
            switch directive {
            case .beginWait: .beginWait
            case .endWait: .endWait
            case .pause(let milliseconds): .pause(milliseconds: milliseconds)
            }
        if let owner {
            try await schedule(projected, envelope: envelope.schedulingEnvelope, owner: owner)
        } else {
            try await schedule(projected, envelope: envelope.schedulingEnvelope)
        }
    }
    public func requiredResources(for call: ActionCall) async throws -> Set<ResourceID> {
        try await requiredResources(for: call.executionRequest.functionRequest)
    }
    public func closeResources(agent: AgentID, incarnation: String) async {
        await closeResources(endpoint: agent.rawValue, incarnation: incarnation)
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
extension ToolCall {
    public var executionRequest: ToolRequest { .init(id: id, toolPath: toolPath, arguments: arguments) }
}

extension ToolResponse {
    func agentResult(roundID: String?, invocation: ActionInvocationSnapshot?) -> ToolResult {
        .init(
            callID: callID, value: value, isError: isError, failureCode: failureCode?.rawValue,
            completion: completion?.agentValue, roundID: roundID, invocation: invocation)
    }
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
