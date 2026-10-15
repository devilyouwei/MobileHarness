import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import Storage

// Test callers explicitly cross the same validated Gateway boundary as production.
extension ActionInvocation {
    init(envelope: OutputEnvelope) throws {
        self = try ScheduledAction(envelope: envelope).execution
    }
    init(source: AgentID, input: AgentInput, call: ActionCall, sequence: UInt64 = 0) {
        self =
            ScheduledAction(
                source: source, input: input, call: call, sequence: sequence, executionID: UUID().uuidString
            ).execution
    }
}
extension ChannelScheduler {
    func enqueue(invocation: any FunctionInput) async throws -> String {
        try await enqueue(invocation: ScheduledAction(envelope: invocation.testEnvelope))
    }
}
extension FunctionInput {
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
                    actionPath: .init(
                        domain: call.actionPath.domain, module: call.actionPath.module,
                        function: call.actionPath.function),
                    channel: (self as? ActionInvocation)?.channel ?? "main", parameters: call.parameters)),
            sequence: context.sequence)
    }
}
extension ActionExecutor {
    func execute(_ invocation: ScheduledAction) async throws -> ActionCompletion {
        try await execute(invocation.execution)
    }
}
extension ActionBinding {
    init(
        path: ActionPath, displayName: String, kind: Kind, completion: String, resources: Set<ResourceID> = [],
        handler: @escaping ActionHandler
    ) {
        self.init(
            path: .init(domain: path.domain, module: path.module, function: path.function), displayName: displayName,
            kind: kind,
            completion: completion,
            resources: Set(resources.map { ActionResource(rawValue: $0.rawValue) }),
            handler: handler)
    }
    init(
        path: ActionPath, displayName: String, kind: Kind, completion: String, resources: Set<ResourceID> = [],
        completing: @escaping ActionCompletionHandler
    ) {
        self.init(
            path: .init(domain: path.domain, module: path.module, function: path.function), displayName: displayName,
            kind: kind,
            completion: completion,
            resources: Set(resources.map { ActionResource(rawValue: $0.rawValue) }),
            completing: completing)
    }
}
extension ToolExecutor {
    func execute(_ call: ToolCall, envelope: OutputEnvelope) async throws -> ToolResponse? {
        try await execute(call.executionRequest, context: envelope.executionContext)
    }
}
extension ActionInvocation {
    init(call: ToolCall, envelope: OutputEnvelope) {
        self.init(tool: call.executionRequest, context: envelope.executionContext)
    }
}

extension ActionPath {
    var executionIdentifier: ActionIdentifier { .init(domain: domain, module: module, function: function) }
}

extension ActionInvocation {
    init(call: ToolRequest, context: ActionExecutionContext) {
        self.init(tool: call, context: context)
    }
}

struct ScheduledFunctionFixture: ActionModule {
    let definitions: [ActionBinding]
    init(_ module: any CapabilityModule) {
        definitions = module.definitions.map { ActionBinding(function: $0) }
    }
}
