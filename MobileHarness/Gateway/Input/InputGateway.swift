import AgentCore
import Foundation

public actor InputGateway {
    private var activeAdmissions = 0
    private var activeBranches = 0
    private var observationBytes = 0
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
    // Module-internal: only OutputGateway supplies resolved targets and a bound source identity.
    func sendInternal(_ input: AgentInput, targets: [(AgentID, UUID)]) async throws -> DeliveryReport {
        guard input.metadata.origin == .agent, input.metadata.incarnation != nil else {
            throw CommunicationError.unauthorized
        }
        return try await deliver(input, targets: targets.map { ($0.0, Optional($0.1)) })
    }
    private func validatePayload(_ input: AgentInput) throws -> Int {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        guard input.metadata.contract == InputMetadata(payload: input.payload).contract,
            input.metadata.version == 1, input.metadata.hops >= 0, input.metadata.hops <= 8,
            input.metadata.capturedAt.isFinite, input.metadata.capturedAt >= 0
        else { throw CommunicationError.invalidPayload }
        switch input.metadata.origin {
        case .external:
            guard input.metadata.incarnation == nil else { throw CommunicationError.unauthorized }
        case .agent:
            guard input.metadata.incarnation != nil else { throw CommunicationError.unauthorized }
        case .runtime:
            guard input.metadata.source == "runtime", input.metadata.incarnation == nil else {
                throw CommunicationError.unauthorized
            }
        }
        switch input.payload {
        case .actionResult(let result):
            guard result.owner.sessionID == input.sessionID, result.owner.agent.rawValue.utf8.count <= 64,
                result.path.domain.utf8.count <= 64, result.path.module.utf8.count <= 64,
                result.path.function.utf8.count <= 64,
                result.status != .succeeded || result.completion != nil,
                (result.status == .succeeded) == (result.failure == nil)
            else { throw CommunicationError.invalidPayload }
            if case .value(let value) = result.completion, value.utf8.count > 65_536 {
                throw CommunicationError.invalidPayload
            }
            if result.status != .succeeded, let completion = result.completion {
                // Failed/cancelled reports retain partial effects; success-only completion kinds are invalid.
                guard case .report = completion else { throw CommunicationError.invalidPayload }
            }
        case .activityEvent(let event):
            guard event.owner.sessionID == input.sessionID, event.owner.agent.rawValue.utf8.count <= 64,
                event.sequence > 0
            else { throw CommunicationError.invalidPayload }
        case .observation(let value): return try (policy?.contracts ?? .standard).validatedSize(value)
        case .text(let value): guard value.utf8.count <= 4096 else { throw CommunicationError.invalidPayload }
        case .event(let value): guard value.utf8.count <= 16384 else { throw CommunicationError.invalidPayload }
        default: break
        }
        return 0
    }
    public func publish(_ input: AgentInput) async throws -> DeliveryReport {
        try validateExternal(input)
        return try await deliver(input, targets: destinations(for: input).map { ($0, nil) })
    }
    public func send(_ input: AgentInput, to target: AgentID) async throws -> DeliveryReport {
        try validateExternal(input)
        return try await deliver(input, targets: [(target, nil)])
    }
    private func validateExternal(_ input: AgentInput) throws {
        guard input.metadata.origin == .external, input.metadata.incarnation == nil else {
            throw CommunicationError.unauthorized
        }
        switch input.payload {
        case .toolResult, .actionResult, .activityEvent: throw CommunicationError.unauthorized
        default: break
        }
    }

    /// Module-internal: returning Tools bind the original execution owner, never public external admission.
    func deliverToolResult(_ result: ToolResult, owner: ExecutionOwner, envelope: OutputEnvelope) async throws
        -> DeliveryReport?
    {
        guard owner.agent == envelope.source, owner.sessionID == envelope.sessionID else {
            throw CommunicationError.unauthorized
        }
        try await manager.validate(owner.agent, incarnation: owner.incarnation, sessionID: owner.sessionID)
        let agent = try await manager.agent(owner.agent)
        guard agent.descriptor.inputs.contains(.toolResult) else { return nil }
        if case .value(let value) = result.completion, value.utf8.count > 65_536 {
            throw CommunicationError.invalidPayload
        }
        let context = envelope.inputMetadata
        guard (0..<8).contains(context.hops) else { throw CommunicationError.hopLimitExceeded }
        let payload = InputPayload.toolResult(result)
        let input = AgentInput(
            sessionID: owner.sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "runtime", origin: .runtime, sequence: envelope.sequence,
                rootID: context.rootID, parentID: envelope.inputID, hops: context.hops + 1),
            turn: envelope.turn)
        return try await deliver(input, targets: [(owner.agent, owner.incarnation)])
    }

    public func deliverActionResult(_ result: ActionResult) async -> ActionResultDelivery {
        await deliverFeedback(.actionResult(result), owner: result.owner, causality: result.causality)
    }

    public func deliverActivityEvent(_ event: ActivityEvent) async -> ActionResultDelivery {
        await deliverFeedback(
            .activityEvent(event), owner: event.owner,
            causality: event.causality, sequence: event.sequence)
    }

    private func deliverFeedback(
        _ payload: InputPayload, owner: ExecutionOwner, causality: SignalCausality, sequence: UInt64? = nil
    ) async -> ActionResultDelivery {
        guard (0..<8).contains(causality.hops) else { return .closed }
        let input = AgentInput(
            sessionID: owner.sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "runtime", origin: .runtime,
                sequence: sequence ?? causality.sequence, rootID: causality.rootID,
                parentID: causality.inputID, hops: causality.hops + 1), turn: causality.turn)
        return await deliverRuntime(input, owner: owner)
    }

    private func deliverRuntime(_ input: AgentInput, owner: ExecutionOwner) async -> ActionResultDelivery {
        do {
            try await manager.validate(owner.agent, incarnation: owner.incarnation, sessionID: owner.sessionID)
            let agent = try await manager.agent(owner.agent)
            guard agent.descriptor.inputs.contains(input.payload.kind),
                policy?.accepts(input, target: owner.agent) ?? true
            else { return .closed }
        } catch { return .closed }
        do {
            let report = try await deliver(input, targets: [(owner.agent, owner.incarnation)])
            if report.rejected.isEmpty { return .accepted }
            do {
                try await manager.validate(owner.agent, incarnation: owner.incarnation, sessionID: owner.sessionID)
            } catch { return .closed }
            return .retry
        } catch CommunicationError.capacityExceeded { return .retry } catch { return .closed }
    }

    private func deliver(_ input: AgentInput, targets: [(AgentID, UUID?)]) async throws -> DeliveryReport {
        try Task.checkCancellation()
        let encodedBytes = try validatePayload(input)
        guard !targets.isEmpty else { throw CommunicationError.noRecipients }
        guard targets.count <= 16, Set(targets.map(\.0)).count == targets.count else {
            throw CommunicationError.capacityExceeded
        }
        if input.metadata.origin == .external {
            guard (policy?.externalSources ?? ["user", "runtime"]).contains(input.metadata.source) else {
                throw CommunicationError.unauthorized
            }
        }
        let retainedBytes = encodedBytes * targets.count
        guard activeAdmissions < 128, activeBranches + targets.count <= 256,
            observationBytes + retainedBytes <= 8 * 1024 * 1024
        else { throw CommunicationError.capacityExceeded }
        activeAdmissions += 1
        activeBranches += targets.count
        observationBytes += retainedBytes
        defer {
            activeAdmissions -= 1
            activeBranches -= targets.count
            observationBytes -= retainedBytes
        }
        // Structured calls only: no retained tasks, timeout racers or communication mailbox.
        return await withTaskGroup(of: (AgentID, String?).self) { group in
            for (target, expectedIncarnation) in targets {
                group.addTask { [manager, policy] in
                    do {
                        try Task.checkCancellation()
                        if let policy, !policy.accepts(input, target: target) {
                            throw CommunicationError.unsupportedContract
                        }
                        if input.metadata.incarnation != nil, policy == nil {
                            throw CommunicationError.unsupportedContract
                        }
                        let incarnation: UUID
                        if let expectedIncarnation {
                            incarnation = expectedIncarnation
                        } else {
                            incarnation = try await manager.identity(target)
                        }
                        try await manager.validate(target, incarnation: incarnation, sessionID: input.sessionID)
                        let agent = try await manager.agent(target)
                        guard agent.descriptor.inputs.contains(input.payload.kind) else {
                            throw HarnessError.unsupportedInput
                        }
                        if let sourceIncarnation = input.metadata.incarnation {
                            try await manager.validate(
                                AgentID(rawValue: input.metadata.source), incarnation: sourceIncarnation,
                                sessionID: input.sessionID)
                        }
                        try await manager.validate(target, incarnation: incarnation, sessionID: input.sessionID)
                        try Task.checkCancellation()
                        guard !input.metadata.expired else { throw CommunicationError.expired }
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
