import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Testing

@testable import Agents
@testable import Gateway

private struct FixtureActionModule: ActionModule { let definitions: [ActionBinding] }
private struct FixtureToolModule: ToolModule { let definitions: [ActionBinding] }

func fixtureDescriptor(_ binding: ActionBinding) -> ActionExecutionDescriptor {
    .init(
        path: binding.path, declaration: binding.function.declaration, displayName: binding.displayName,
        kind: binding.kind, protocols: binding.protocols, executionPolicy: binding.executionPolicy,
        directResultPolicy: binding.directResultPolicy)
}

/// Legacy scenario fixtures use the actual module container; production has no registry-based Gateway API.
func fixtureExecutionPort(actions: [ActionBinding], tools: [ActionBinding] = []) -> ActionsExecutionPort {
    let instance = Task { @MainActor in
        var definitions: [ActionIdentifier: ActionFunction] = [:]
        for binding in actions + tools where definitions[binding.path] == nil {
            definitions[binding.path] = binding.function
        }
        let assembly = try BehaviorAssembly(
            actionModules: [FixtureActionModule(definitions: actions)],
            toolModules: [FixtureToolModule(definitions: tools)],
            functions: FunctionRegistry(definitions: Array(definitions.values)))
        let root = ActionsContainer()
        try root.configure(assembly)
        try root.start()
        return root
    }
    return ActionsExecutionPort(
        catalog: {
            let root = try await instance.value
            return try await root.catalog()
        },
        prepare: { input, callProtocol in
            let root = try await instance.value
            let port = await root.execution
            return try await port.prepare(input, callProtocol)
        },
        execute: { ticket in
            let root = try await instance.value
            let port = await root.execution
            return try await port.execute(ticket)
        },
        discard: { ticket in
            guard let root = try? await instance.value else { return }
            let port = await root.execution
            await port.discard(ticket)
        })
}

extension ChannelScheduler {
    init(
        registry: ActionRegistry, capacityPerChannel: Int = 32, maximumTrackedInputs: Int = 64,
        maximumChannels: Int = 16, diagnosticCapacity: Int = 256, resources: ResourceCoordinator? = nil,
        resultCapacity: Int = 512, admission: GatewayAdmission? = nil,
        deliverResult: @escaping @Sendable (ActionResult) async -> ActionResultDelivery = { _ in .closed }
    ) {
        self.init(
            executor: fixtureExecutionPort(actions: registry.bindings), capacityPerChannel: capacityPerChannel,
            maximumTrackedInputs: maximumTrackedInputs, maximumChannels: maximumChannels,
            diagnosticCapacity: diagnosticCapacity, resources: resources, resultCapacity: resultCapacity,
            admission: admission, deliverResult: { await deliverResult($0.agentValue) })
    }
}

extension InputGateway {
    init(
        manager: AgentManager, policy: CommunicationPolicy? = nil,
        signalAggregation: @escaping @Sendable (AgentInput) -> Bool = {
            [.audio, .image, .activityEvent].contains($0.payload.kind)
        },
        signalSummary: @escaping @Sendable (AgentInput) -> String = { _ in "" },
        publicationFailure: @escaping @Sendable (AgentInput, AgentID?, String) async -> Void = { _, _, _ in },
        admission: GatewayAdmission? = nil
    ) {
        self.init(
            manager: manager, policy: policy, signals: SignalTransport(admission: admission),
            signalAggregation: signalAggregation, signalSummary: signalSummary,
            publicationFailure: publicationFailure, admission: admission)
    }
}

extension OutputGateway {
    init(
        manager: AgentManager, requests: InputGateway, tools: ToolRegistry,
        actions: ChannelScheduler? = nil, policy: CommunicationPolicy? = nil,
        actionFeedback: ActionFeedback = .failuresOnly, observedContracts: Set<String> = [],
        observeEvent: (@Sendable (AgentInput) async throws -> Void)? = nil,
        admission: GatewayAdmission? = nil, sink: @escaping Sink
    ) async {
        let toolBindings = await tools.bindings()
        let executor = fixtureExecutionPort(actions: [], tools: toolBindings)
        let fence = admission ?? GatewayAdmission()
        if admission == nil { fence.setOpen(true) }
        let coordinator: ResourceCoordinator
        if let supplied = actions?.resourceCoordinator {
            coordinator = supplied
        } else {
            // Empty definitions are a valid fixture, independent of business/device availability.
            do { coordinator = try ResourceCoordinator(definitions: [], admission: admission) } catch {
                preconditionFailure("Invalid empty fixture resources: \(error)")
            }
        }
        let scheduler = actions ?? ChannelScheduler(executor: fixtureExecutionPort(actions: []), admission: admission)
        self.init(
            manager: manager, requests: requests,
            catalog: .init(revision: UUID(), entries: toolBindings.map(fixtureDescriptor)), actions: scheduler,
            direct: DirectExecutionDispatcher(executor: executor, resources: coordinator, admission: fence),
            policy: policy, actionFeedback: actionFeedback, observedContracts: observedContracts,
            observeEvent: observeEvent, admission: admission, sink: sink)
    }
}

extension ActionExecutionLedger {
    mutating func admit(_ invocation: ScheduledAction, definition: ActionBinding) {
        admit(invocation, definition: fixtureDescriptor(definition))
    }
}

extension BehaviorCoverage {
    static func validate(actions: ActionRegistry, toolPaths: Set<String>, capabilities: [CapabilityRegistry]) throws {
        var entries = actions.bindings.map(fixtureDescriptor)
        for path in toolPaths {
            let pieces = path.split(separator: ".").map(String.init)
            guard pieces.count == 3 else { throw HarnessError.forbiddenTool }
            entries.append(
                .init(
                    path: .init(domain: pieces[0], module: pieces[1], function: pieces[2]), declaration: nil,
                    displayName: path, kind: .finite, protocols: [.tool], executionPolicy: .direct,
                    directResultPolicy: .returning))
        }
        try validate(catalog: .init(revision: UUID(), entries: entries), capabilities: capabilities)
    }
}

func == (lhs: String, rhs: AgentID) -> Bool { lhs == rhs.rawValue }
func == (lhs: AgentID, rhs: String) -> Bool { lhs.rawValue == rhs }
func == (lhs: ActionIdentifier, rhs: ActionPath) -> Bool { lhs == rhs.executionIdentifier }
func == (lhs: ActionPath, rhs: ActionIdentifier) -> Bool { lhs.executionIdentifier == rhs }

extension ActionRegistry {
    func validate(capabilities: CapabilityRegistry) throws {
        for path in capabilities.actions.map(\.path) + capabilities.internalActions.map(\.path) {
            _ = try definition(for: path.executionIdentifier)
        }
    }
}
extension ExecutionResult {
    var report: ActionReport? { if case .report(let value) = completion { value } else { nil } }
}
