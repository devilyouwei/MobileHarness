import AgentCore
import Foundation
import FunctionContracts
import Gateway

/// Agent-owned interpretation and policy; Gateway sees only the injected neutral execution engine.
public struct AgentGatewayConfiguration: Sendable {
    public let catalog: ActionCatalogSnapshot
    public let policy: CommunicationPolicy?
    public let signalSummary: @Sendable (AgentInput) -> String
    public let observedContracts: Set<String>
    public let observeEvent: (@Sendable (AgentInput) async throws -> Void)?
    public let publicationSettled: @Sendable (AgentInput, Set<AgentID>, [AgentID: String]) async -> Void
    public let sink: OutputGateway.Sink
    public init(
        catalog: ActionCatalogSnapshot, policy: CommunicationPolicy? = nil,
        signalSummary: @escaping @Sendable (AgentInput) -> String = { _ in "" },
        observedContracts: Set<String> = [], observeEvent: (@Sendable (AgentInput) async throws -> Void)? = nil,
        publicationSettled: @escaping @Sendable (AgentInput, Set<AgentID>, [AgentID: String]) async -> Void = {
            _, _, _ in
        },
        sink: @escaping OutputGateway.Sink = { _ in }
    ) {
        self.catalog = catalog
        self.policy = policy
        self.signalSummary = signalSummary
        self.observedContracts = observedContracts
        self.observeEvent = observeEvent
        self.publicationSettled = publicationSettled
        self.sink = sink
    }
}
public struct AgentGatewayCapabilities: Sendable {
    public let observations: AgentObservationAccess
    public let manager: AgentManager
    public let input: InputGateway
    public let output: OutputGateway
    public let execution: any ActionExecutionEngine
}
public struct AgentObservationSession: Sendable {
    let scope: GatewayObservationSession
    public let capabilities: AgentGatewayCapabilities
}
public struct AgentObservationAccess: Sendable {
    let access: GatewayObservationAccess
}
