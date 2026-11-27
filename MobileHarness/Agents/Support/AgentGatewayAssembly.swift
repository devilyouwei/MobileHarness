import AgentCore
import Foundation
import FunctionContracts
import Gateway

extension AgentObservationAccess {
    @MainActor public func open(
        policy: CommunicationPolicy, observedContracts: Set<String>,
        observeEvent: @escaping @Sendable (AgentInput) async throws -> Void
    ) throws -> AgentObservationSession {
        let manager = AgentManager()
        let scope = try access.open()
        let execution = DetachedActionExecution()
        let input = InputGateway(
            manager: manager, policy: policy, signals: scope.capabilities.signals,
            admission: scope.capabilities.admission)
        let emptyCatalog = ActionCatalogSnapshot(revision: UUID(), entries: [])
        let output = OutputGateway(
            manager: manager, requests: input, catalog: emptyCatalog,
            execution: execution, policy: policy,
            observedContracts: observedContracts, observeEvent: observeEvent, admission: scope.capabilities.admission,
            sink: { _ in })
        return AgentObservationSession(
            scope: scope,
            capabilities: .init(
                observations: self, manager: manager,
                input: input, output: output, execution: execution))
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
    private let manager: AgentManager
    private let input: InputGateway
    private let cognitive: AgentGatewayConfiguration
    public init(
        signals: SignalTransport, admission: GatewayAdmission,
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
    }
    public func bind(
        ports: GatewayCapabilities, observations: GatewayObservationAccess, engine: any ActionExecutionHost
    ) async throws -> AgentGatewayCapabilities {
        let input = self.input
        let execution = try await ActionExecutionTransport.connect(
            ports: ports, engine: engine,
            receiveActionResult: { try await input.receiveActionResult($0, deadline: $1) },
            deliverStart: { await input.deliverActionStart($0) },
            deliverControl: { await input.deliverActionControl($0) })
        let output = OutputGateway(
            manager: manager, requests: input, catalog: cognitive.catalog,
            execution: execution, policy: cognitive.policy,
            actionFeedback: .terminal, observedContracts: cognitive.observedContracts,
            observeEvent: cognitive.observeEvent, admission: ports.admission, sink: cognitive.sink)
        return .init(
            observations: .init(access: observations), manager: manager, input: input,
            output: output, execution: execution)
    }
}
