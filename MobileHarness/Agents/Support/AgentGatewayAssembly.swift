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
        let scope = try access.open(
            configuration: .init(
                engine: DetachedActionExecution(),
                deliverResult: { await receiver.deliver($0) }))
        let input = InputGateway(
            manager: manager, policy: policy, signals: scope.capabilities.signals,
            admission: scope.capabilities.admission)
        receiver.bind(input)
        let emptyCatalog = ActionCatalogSnapshot(revision: UUID(), entries: [])
        let output = OutputGateway(
            manager: manager, requests: input, catalog: emptyCatalog,
            execution: scope.capabilities.execution, policy: policy,
            observedContracts: observedContracts, observeEvent: observeEvent, admission: scope.capabilities.admission,
            sink: { _ in })
        return AgentObservationSession(
            scope: scope,
            capabilities: .init(
                observations: self, manager: manager,
                input: input, output: output, execution: scope.capabilities.execution))
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
    public init(
        signals: SignalTransport, admission: GatewayAdmission, engine: any ActionExecutionEngine,
        configuration: AgentGatewayConfiguration
    ) {
        let manager = AgentManager()
        let input = InputGateway(
            manager: manager, policy: configuration.policy, signals: signals,
            requestImplementations: AgentContracts.requestImplementations,
            eventImplementations: AgentContracts.eventImplementations,
            signalSummary: configuration.signalSummary, publicationSettled: configuration.publicationSettled,
            admission: admission)
        self.manager = manager
        self.input = input
        self.cognitive = configuration
        self.configuration = GatewayConfiguration(
            engine: engine, deliverResult: { await input.deliverActionResult($0.agentValue) },
            deliverStart: { await input.deliverActionStart($0) },
            deliverControl: { await input.deliverActionControl($0) })
    }
    public func bind(ports: GatewayCapabilities, observations: GatewayObservationAccess) -> AgentGatewayCapabilities {
        let output = OutputGateway(
            manager: manager, requests: input, catalog: cognitive.catalog,
            execution: ports.execution, policy: cognitive.policy,
            actionFeedback: .terminal, observedContracts: cognitive.observedContracts,
            observeEvent: cognitive.observeEvent, admission: ports.admission, sink: cognitive.sink)
        return .init(
            observations: .init(access: observations), manager: manager, input: input,
            output: output, execution: ports.execution)
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
