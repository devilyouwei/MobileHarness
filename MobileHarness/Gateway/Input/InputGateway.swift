import AgentCore
import Foundation

public actor InputGateway {
    private let policy: CommunicationPolicy?
    private let manager: AgentManager
    private let router: any SignalRouter
    public init(
        manager: AgentManager, router: any SignalRouter = LogicRouter(),
        policy: CommunicationPolicy? = nil
    ) {
        self.policy = policy
        self.manager = manager
        self.router = router
    }

    public func destinations(for input: AgentInput) throws -> [AgentID] {
        guard let policy else { throw CommunicationError.unsupportedContract }
        let targets = policy.destinations(for: input)
        guard !targets.isEmpty else { throw CommunicationError.noRecipients }
        return targets
    }
    public func receiveInternal(_ input: AgentInput, target: AgentID, incarnation: UUID) async throws {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        guard policy?.accepts(input, target: target) == true else { throw CommunicationError.unsupportedContract }
        guard let sourceIncarnation = input.metadata.incarnation else { throw CommunicationError.unauthorized }
        try await manager.validate(
            AgentID(rawValue: input.metadata.source), incarnation: sourceIncarnation, sessionID: input.sessionID)
        try await manager.validate(target, incarnation: incarnation, sessionID: input.sessionID)
        let agent = try await manager.agent(target)
        try await agent.receive(input)
    }
    public func publish(_ input: AgentInput) async throws -> DeliveryReport {
        guard input.metadata.incarnation == nil else { throw CommunicationError.unauthorized }
        return try await deliver(input, targets: destinations(for: input))
    }
    public func send(_ input: AgentInput, to target: AgentID) async throws -> DeliveryReport {
        guard input.metadata.incarnation == nil else { throw CommunicationError.unauthorized }
        return try await deliver(input, targets: [target])
    }
    private func deliver(_ input: AgentInput, targets: [AgentID]) async throws -> DeliveryReport {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        guard ["user", "phone.microphone", "phone.camera", "runtime"].contains(input.metadata.source) else {
            throw CommunicationError.unauthorized
        }
        let distinct = Set(targets)
        guard distinct.count <= 16 else { throw CommunicationError.capacityExceeded }
        return await withTaskGroup(of: (AgentID, String?).self) { group in
            for target in distinct {
                group.addTask { [manager, policy] in
                    do {
                        if let policy, !policy.accepts(input, target: target) {
                            throw CommunicationError.unsupportedContract
                        }
                        let incarnation = try await manager.identity(target)
                        try await manager.validate(target, incarnation: incarnation, sessionID: input.sessionID)
                        let agent = try await manager.agent(target)
                        guard agent.descriptor.inputs.contains(input.payload.kind) else {
                            throw HarnessError.unsupportedInput
                        }
                        try await agent.receive(input)
                        return (target, nil)
                    } catch { return (target, String(describing: error)) }
                }
            }
            var delivered: [AgentID] = []
            var rejected: [AgentID: String] = [:]
            for await (id, error) in group { if let error { rejected[id] = error } else { delivered.append(id) } }
            return DeliveryReport(delivered: delivered, rejected: rejected)
        }
    }

    /// Fan-out is best-effort; one rejected destination does not suppress delivery to others.
    public func submit(_ input: AgentInput, to target: AgentID? = nil) async throws -> DeliveryReport {
        let destinations: [AgentID]
        if let target { destinations = [target] } else { destinations = try await router.destinations(for: input) }
        return try await deliver(input, targets: destinations)
    }
}
