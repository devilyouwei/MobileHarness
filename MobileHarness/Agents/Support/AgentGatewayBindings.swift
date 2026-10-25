import AgentCore
import Foundation
import FunctionContracts
import Gateway
import Synchronization

/// Agent-owned interpretation and policy; Gateway sees only the injected neutral execution port.
public struct AgentGatewayConfiguration: Sendable {
    public let executor: ActionsExecutionPort
    public let catalog: ActionCatalogSnapshot
    public let policy: CommunicationPolicy?
    public let resources: [ResourceDefinition]
    public let signalSummary: @Sendable (AgentInput) -> String
    public let observedContracts: Set<String>
    public let observeEvent: (@Sendable (AgentInput) async throws -> Void)?
    public let sink: OutputGateway.Sink
    public init(
        executor: ActionsExecutionPort, catalog: ActionCatalogSnapshot, policy: CommunicationPolicy? = nil,
        resources: [ResourceDefinition] = [], signalSummary: @escaping @Sendable (AgentInput) -> String = { _ in "" },
        observedContracts: Set<String> = [], observeEvent: (@Sendable (AgentInput) async throws -> Void)? = nil,
        sink: @escaping OutputGateway.Sink = { _ in }
    ) {
        self.executor = executor
        self.catalog = catalog
        self.policy = policy
        self.resources = resources
        self.signalSummary = signalSummary
        self.observedContracts = observedContracts
        self.observeEvent = observeEvent
        self.sink = sink
    }
}
public struct AgentGatewayCapabilities: Sendable {
    public let observations: AgentObservationAccess
    public let manager: AgentManager
    public let input: InputGateway
    public let output: OutputGateway
    public let actions: ChannelScheduler
    public let resources: ResourceCoordinator
}
public struct AgentObservationSession: Sendable {
    let scope: GatewayObservationSession
    public let capabilities: AgentGatewayCapabilities
}
public struct AgentObservationAccess: Sendable {
    let access: GatewayObservationAccess
    @MainActor public func open(
        policy: CommunicationPolicy, observedContracts: Set<String>,
        observeEvent: @escaping @Sendable (AgentInput) async throws -> Void
    ) throws -> AgentObservationSession {
        let manager = AgentManager()
        let receiver = AgentResultReceiver()
        let emptyCatalog = ActionCatalogSnapshot(revision: UUID(), entries: [])
        let observationOnly = ActionsExecutionPort(
            catalog: { emptyCatalog },
            prepare: { input, _ in throw ActionExecutionError.missingHandler(input.call.actionPath) },
            execute: { _ in throw ActionExecutionError.invalidInvocation }, discard: { _ in })
        let scope = try access.open(
            configuration: .init(
                executor: observationOnly,
                deliverResult: { await receiver.deliver($0) }))
        let input = InputGateway(
            manager: manager, policy: policy, signals: scope.capabilities.signals,
            admission: scope.capabilities.admission)
        receiver.bind(input)
        let output = OutputGateway(
            manager: manager, requests: input, catalog: emptyCatalog,
            actions: scope.capabilities.actions, direct: scope.capabilities.direct, policy: policy,
            observedContracts: observedContracts, observeEvent: observeEvent, admission: scope.capabilities.admission,
            sink: { _ in })
        return AgentObservationSession(
            scope: scope,
            capabilities: .init(
                observations: self, manager: manager,
                input: input, output: output, actions: scope.capabilities.actions,
                resources: scope.capabilities.resources))
    }
    @MainActor public func close(_ session: AgentObservationSession) async throws {
        for descriptor in await session.capabilities.manager.descriptors() {
            try await session.capabilities.manager.remove(descriptor.id)
        }
        await session.capabilities.output.shutdown(closeResources: false)
        try await access.close(session.scope)
    }
}

@MainActor public enum AgentGatewayAssembly {
    public static func configure(root: GatewayContainer, configuration: AgentGatewayConfiguration) throws
        -> AgentGatewayCapabilities
    {
        let manager = AgentManager()
        let input = InputGateway(
            manager: manager, policy: configuration.policy, signals: root.signals,
            signalSummary: configuration.signalSummary, admission: root.admissionPort)
        let ports = try root.configureExecution(
            .init(
                executor: configuration.executor, resources: configuration.resources,
                deliverResult: { await input.deliverActionResult($0.agentValue) }))
        let output = OutputGateway(
            manager: manager, requests: input, catalog: configuration.catalog,
            actions: ports.actions, direct: ports.direct, policy: configuration.policy,
            actionFeedback: .terminal, observedContracts: configuration.observedContracts,
            observeEvent: configuration.observeEvent, admission: root.admissionPort, sink: configuration.sink)
        return .init(
            observations: .init(access: root.observations),
            manager: manager, input: input, output: output, actions: ports.actions, resources: ports.resources)
    }
}

private final class AgentResultReceiver: Sendable {
    private let input = Mutex<InputGateway?>(nil)
    func bind(_ value: InputGateway) { input.withLock { $0 = value } }
    func deliver(_ result: ExecutionResult) async -> ActionResultDelivery {
        guard let target = input.withLock({ $0 }) else { return .closed }
        return await target.deliverActionResult(result.agentValue)
    }
}
