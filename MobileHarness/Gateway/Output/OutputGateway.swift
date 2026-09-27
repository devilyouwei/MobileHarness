import ActionRuntime
import AgentCore
import Foundation
import ToolRuntime

/// Validates, routes and dispatches output while preserving the existing execution contract.
public actor OutputGateway {
    public typealias Sink = @Sendable (OutputEnvelope) async -> Void
    private let requests: InputGateway
    private let policy: CommunicationPolicy?
    private let observeEvent: (@Sendable (AgentInput) async throws -> Void)?
    private let observedContracts: Set<String>
    private var sequences: [AgentID: UInt64] = [:]
    private var emitting: [AgentID: Int] = [:]
    private let manager: AgentManager
    private let actions: ActionDispatcher
    private let tools: ToolDispatcher
    private let sink: Sink

    public init(
        manager: AgentManager, requests: InputGateway, tools: ToolRegistry,
        actions: ChannelScheduler = ChannelScheduler(registry: ActionRegistry(handlers: [:])),
        policy: CommunicationPolicy? = nil,
        observedContracts: Set<String> = [],
        observeEvent: (@Sendable (AgentInput) async throws -> Void)? = nil,
        sink: @escaping Sink
    ) {
        self.requests = requests
        self.policy = policy
        self.observedContracts = observedContracts
        self.observeEvent = observeEvent
        self.manager = manager
        self.tools = ToolDispatcher(registry: tools, input: requests)
        self.actions = ActionDispatcher(executor: actions)
        self.sink = sink
    }

    public func messaging(for source: AgentID) async throws -> AgentMessaging {
        let incarnation = try await manager.identity(source)
        guard policy?.agents[source] != nil else { throw CommunicationError.unauthorized }
        return AgentMessaging { [weak self] observation, parent, target in
            guard let self else { throw CommunicationError.scopeClosed }
            return try await self.emit(
                observation, parent: parent, source: source, incarnation: incarnation, target: target)
        }
    }
    private func emit(
        _ observation: PerceptionObservation, parent: AgentInput, source: AgentID,
        incarnation: UUID, target: AgentID?
    ) async throws -> DeliveryReport {
        try Task.checkCancellation()
        guard let policy, let declaration = policy.agents[source] else {
            throw CommunicationError.unauthorized
        }
        guard emitting[source, default: 0] < 16 else { throw CommunicationError.capacityExceeded }
        emitting[source, default: 0] += 1
        defer { emitting[source, default: 1] -= 1 }
        try await manager.validate(source, incarnation: incarnation, sessionID: parent.sessionID)
        _ = try observation.validatedSize()
        if let target {
            guard
                declaration.sends.contains(where: {
                    $0.contract == observation.contract && $0.target == target.rawValue
                })
            else {
                throw CommunicationError.unauthorized
            }
        } else {
            guard declaration.publications.contains(observation.contract) else { throw CommunicationError.unauthorized }
        }
        guard (0..<8).contains(parent.metadata.hops) else { throw CommunicationError.hopLimitExceeded }
        guard !parent.metadata.expired else { throw CommunicationError.expired }
        sequences[source, default: 0] += 1
        let payload = InputPayload.observation(observation)
        let input = AgentInput(
            sessionID: parent.sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: source.rawValue, incarnation: incarnation,
                capturedAt: parent.metadata.capturedAt, sequence: sequences[source]!, rootID: parent.metadata.rootID,
                parentID: parent.id, hops: parent.metadata.hops + 1,
                deadline: min(
                    parent.metadata.deadline,
                    .now.advanced(
                        by: .seconds(
                            observation.contract == "vision.pose"
                                ? 1 : observation.contract == "speech.partial" ? 2 : 10)))),
            turn: parent.turn)
        let destinations = target.map { [$0] } ?? policy.destinations(for: input)
        let observed = target == nil && observedContracts.contains(observation.contract) && observeEvent != nil
        guard !destinations.isEmpty || observed else { throw CommunicationError.noRecipients }
        var targets: [(AgentID, UUID)] = []
        var unavailable: [AgentID: String] = [:]
        for id in destinations {
            do { targets.append((id, try await manager.identity(id))) } catch {
                unavailable[id] = String(describing: error)
            }
        }
        // The observer is a runtime/UI endpoint, never a direct business-Agent callback.
        try Task.checkCancellation()
        try await manager.validate(source, incarnation: incarnation, sessionID: input.sessionID)
        guard !input.metadata.expired else { throw CommunicationError.expired }
        if observed { try await observeEvent?(input) }
        let report = targets.isEmpty ? DeliveryReport() : try await requests.sendInternal(input, targets: targets)
        return DeliveryReport(
            delivered: report.delivered, rejected: unavailable.merging(report.rejected) { _, new in new })
    }

    public func cancel(sessionID: UUID) async { await actions.cancel(sessionID: sessionID) }
    public func shutdown() async { await actions.shutdown() }

    /// Admission is not playback completion. The terminal control joins accepted actions.
    public func dispatch(_ envelope: OutputEnvelope) async throws {
        try Task.checkCancellation()
        let descriptor = try await manager.agent(envelope.source).descriptor
        try Task.checkCancellation()
        try OutputValidator.validate(envelope.output, descriptor: descriptor)
        switch try ExecutionRouter.route(envelope.output) {
        case .action(let token):
            try await actions.dispatch(token, envelope: envelope)
        case .tool(let call):
            try await tools.dispatch(call, envelope: envelope)
        case .finish:
            try await actions.finish(envelope)
        case .cancel:
            await actions.cancel(envelope)
        case .observe: break
        }
        try Task.checkCancellation()
        await sink(envelope)
    }
}
