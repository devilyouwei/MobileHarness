import AgentCore
import Foundation

public actor InputGateway {
    private var activeAdmissions = 0
    private let policy: CommunicationPolicy?
    private let manager: AgentManager
    public init(
        manager: AgentManager, policy: CommunicationPolicy? = nil
    ) {
        self.policy = policy
        self.manager = manager
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
        try await manager.validate(target, incarnation: incarnation, sessionID: input.sessionID)
        try validatePayload(input)
        try Task.checkCancellation()
        try await agent.receive(input)
    }
    private func validatePayload(_ input: AgentInput) throws {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        guard input.metadata.contract == InputMetadata(payload: input.payload).contract,
            input.metadata.version == 1, input.metadata.hops >= 0, input.metadata.hops <= 8,
            input.metadata.capturedAt.isFinite, input.metadata.capturedAt >= 0
        else { throw CommunicationError.invalidPayload }
        switch input.payload {
        case .observation(let value): _ = try value.validatedSize()
        case .text(let value): guard value.utf8.count <= 4096 else { throw CommunicationError.invalidPayload }
        case .event(let value): guard value.utf8.count <= 16384 else { throw CommunicationError.invalidPayload }
        default: break
        }
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
        try validatePayload(input)
        guard activeAdmissions < 128 else { throw CommunicationError.capacityExceeded }
        activeAdmissions += 1
        defer { activeAdmissions -= 1 }
        guard input.metadata.incarnation == nil else { throw CommunicationError.unauthorized }
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
}
