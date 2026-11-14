import AgentCore
import Foundation
import FunctionContracts
import Gateway
import Synchronization

extension AgentObservationAccess {
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

@MainActor public final class AgentGatewayAssembly {
    public let configuration: GatewayConfiguration
    private let manager: AgentManager
    private let input: InputGateway
    private let cognitive: AgentGatewayConfiguration
    public init(signals: SignalTransport, admission: GatewayAdmission, configuration: AgentGatewayConfiguration) {
        let manager = AgentManager()
        let input = InputGateway(
            manager: manager, policy: configuration.policy, signals: signals,
            signalSummary: configuration.signalSummary, admission: admission)
        self.manager = manager
        self.input = input
        self.cognitive = configuration
        self.configuration = GatewayConfiguration(
            executor: configuration.executor, resources: configuration.resources,
            deliverResult: { await input.deliverActionResult($0.agentValue) })
    }
    public func bind(ports: GatewayCapabilities, observations: GatewayObservationAccess) -> AgentGatewayCapabilities {
        let output = OutputGateway(
            manager: manager, requests: input, catalog: cognitive.catalog,
            actions: ports.actions, direct: ports.direct, policy: cognitive.policy,
            actionFeedback: .terminal, observedContracts: cognitive.observedContracts,
            observeEvent: cognitive.observeEvent, admission: ports.admission, sink: cognitive.sink)
        return .init(
            observations: .init(access: observations), manager: manager, input: input,
            output: output, actions: ports.actions, resources: ports.resources)
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
