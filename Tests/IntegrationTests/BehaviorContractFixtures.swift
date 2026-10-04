import ActionRuntime
import Actions
import AgentCore
import Foundation
import Gateway
import ToolRuntime
import Tools

// Test callers explicitly cross the same validated Gateway boundary as production.
extension ActionInvocation {
    init(envelope: OutputEnvelope) throws {
        self = try ScheduledAction(envelope: envelope).execution
    }
    init(source: AgentID, input: AgentInput, call: ActionCall, sequence: UInt64 = 0) {
        self = ScheduledAction(source: source, input: input, call: call, sequence: sequence).execution
    }
}
extension ChannelScheduler {
    func enqueue(invocation: ActionInvocation) async throws -> UUID {
        try await enqueue(invocation: ScheduledAction(envelope: invocation.testEnvelope))
    }
}
extension ActionInvocation {
    var testEnvelope: OutputEnvelope {
        OutputEnvelope(
            source: AgentID(rawValue: context.source),
            input: AgentInput(
                id: context.inputID, sessionID: context.sessionID, payload: .event("test"),
                turn: context.correlationID.flatMap { id in
                    context.ordinal.map { AgentTurn(id: id, ordinal: $0) }
                }),
            output: .actionCall(
                ActionCall(
                    actionPath: .init(module: call.actionPath.module, function: call.actionPath.function),
                    channel: call.channel, parameters: call.parameters)), sequence: context.sequence)
    }
}
extension ActionExecutor {
    func execute(_ invocation: ScheduledAction) async throws -> ActionCompletion {
        try await execute(invocation.execution)
    }
}
extension ActionDefinition {
    init(
        path: ActionPath, displayName: String, kind: Kind, completion: String, resources: Set<ResourceID> = [],
        handler: @escaping ActionHandler
    ) {
        self.init(
            path: .init(module: path.module, function: path.function), displayName: displayName, kind: kind,
            completion: completion, resources: Set(resources.map { ActionResource(rawValue: $0.rawValue) }),
            handler: handler)
    }
    init(
        path: ActionPath, displayName: String, kind: Kind, completion: String, resources: Set<ResourceID> = [],
        completing: @escaping ActionCompletionHandler
    ) {
        self.init(
            path: .init(module: path.module, function: path.function), displayName: displayName, kind: kind,
            completion: completion, resources: Set(resources.map { ActionResource(rawValue: $0.rawValue) }),
            completing: completing)
    }
}
extension ToolExecutor {
    func execute(_ call: ToolCall, envelope: OutputEnvelope) async throws -> ToolResponse? {
        try await execute(call.executionRequest, context: envelope.toolContext)
    }
}
extension ToolInvocation {
    init(call: ToolCall, envelope: OutputEnvelope) {
        self.init(call: call.executionRequest, context: envelope.toolContext)
    }
}

extension ActionPath {
    var executionIdentifier: ActionIdentifier { .init(module: module, function: function) }
}
