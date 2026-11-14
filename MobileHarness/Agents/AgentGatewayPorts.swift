import AgentCore
import Foundation
import FunctionContracts
import Gateway

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
}
