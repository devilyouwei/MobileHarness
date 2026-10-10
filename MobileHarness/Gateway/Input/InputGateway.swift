import AgentCore
import Foundation

public actor InputGateway {
    private var signalRecords: [SignalTraceRecord] = []
    private var signalRevision: UInt64 = 0
    private var signalEvictions: UInt64 = 0
    private var signalObservers: [UUID: AsyncStream<SignalTraceSnapshot>.Continuation] = [:]
    private var taskRecords: [SignalTraceRecord] = []
    private var taskRevision: UInt64 = 0
    private var taskEvictions: UInt64 = 0
    private var taskObservers: [UUID: AsyncStream<SignalTraceSnapshot>.Continuation] = [:]
    private let signalAggregation: @Sendable (AgentInput) -> Bool
    private let signalSummary: @Sendable (AgentInput) -> String
    private var publications: [UUID: Task<Void, Never>] = [:]
    private var publicationBranches = 0
    private var publicationBytes = 0
    private var closed = false
    private let allowsExternalSend: Bool
    private let publicationFailure: @Sendable (AgentInput, AgentID?, String) async -> Void
    private var activeAdmissions = 0
    private var activeBranches = 0
    private var observationBytes = 0
    private let policy: CommunicationPolicy?
    private let manager: AgentManager
    public init(
        manager: AgentManager, policy: CommunicationPolicy? = nil, allowsExternalSend: Bool = false,
        signalAggregation: @escaping @Sendable (AgentInput) -> Bool = {
            [.audio, .image, .activityEvent].contains($0.payload.kind)
        },
        signalSummary: @escaping @Sendable (AgentInput) -> String = { _ in "" },
        publicationFailure: @escaping @Sendable (AgentInput, AgentID?, String) async -> Void = { _, _, _ in }
    ) {
        self.signalAggregation = signalAggregation
        self.signalSummary = signalSummary
        self.allowsExternalSend = allowsExternalSend
        self.publicationFailure = publicationFailure
        self.policy = policy
        self.manager = manager
    }

    public func observeSignals() throws -> AsyncStream<SignalTraceSnapshot> {
        guard signalObservers.count + taskObservers.count < 8 else { throw CommunicationError.capacityExceeded }
        let id = UUID()
        let pair = AsyncStream<SignalTraceSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.yield(signalSnapshot())
        if closed {
            pair.continuation.finish()
        } else {
            signalObservers[id] = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSignalObserver(id) }
            }
        }
        return pair.stream
    }
    /// Task protocol diagnostics only; ordinary input traffic never wakes these observers.
    public func observeTasks() throws -> AsyncStream<SignalTraceSnapshot> {
        guard signalObservers.count + taskObservers.count < 8 else { throw CommunicationError.capacityExceeded }
        let id = UUID()
        let pair = AsyncStream<SignalTraceSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.yield(taskSnapshot())
        if closed {
            pair.continuation.finish()
        } else {
            taskObservers[id] = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTaskObserver(id) }
            }
        }
        return pair.stream
    }
    private func removeTaskObserver(_ id: UUID) { taskObservers[id] = nil }
    private func taskSnapshot() -> SignalTraceSnapshot {
        .init(revision: taskRevision, records: taskRecords, evictedCount: taskEvictions)
    }
    private func taskChanged(_ record: SignalTraceRecord) {
        guard record.task != nil else { return }
        if let index = taskRecords.firstIndex(where: { $0.id == record.id }) {
            taskRecords[index] = record
        } else {
            if taskRecords.count == 256 {
                taskRecords.removeFirst()
                taskEvictions &+= 1
            }
            taskRecords.append(record)
        }
        taskRevision &+= 1
        let snapshot = taskSnapshot()
        for observer in taskObservers.values { observer.yield(snapshot) }
    }
    private func removeSignalObserver(_ id: UUID) { signalObservers[id] = nil }
    private func signalSnapshot() -> SignalTraceSnapshot {
        .init(revision: signalRevision, records: signalRecords, evictedCount: signalEvictions)
    }
    private func signalChanged() {
        signalRevision &+= 1
        let snapshot = signalSnapshot()
        for observer in signalObservers.values { observer.yield(snapshot) }
    }
    private func beginSignal(_ input: AgentInput, mode: SignalTraceRecord.Mode, targets: [AgentID]) -> UUID {
        if signalRecords.contains(where: { $0.id == input.id }) { return input.id }
        if signalRecords.count == 256 {
            signalRecords.removeFirst()
            signalEvictions &+= 1
        }
        signalRecords.append(
            .init(
                input: input, mode: mode, targets: targets, summary: signalSummary(input),
                aggregates: signalAggregation(input)))
        taskChanged(signalRecords[signalRecords.count - 1])
        signalChanged()
        return input.id
    }
    private func finishSignal(
        _ id: UUID, phase: SignalTraceRecord.Phase? = nil, reason: String? = nil,
        report: DeliveryReport? = nil
    ) {
        if !signalRecords.contains(where: { $0.id == id }),
            let retained = taskRecords.first(where: { $0.id == id })
        {
            if signalRecords.count == 256 {
                signalRecords.removeFirst()
                signalEvictions &+= 1
            }
            signalRecords.append(retained)
        }
        guard let index = signalRecords.firstIndex(where: { $0.id == id }) else { return }
        if let report {
            signalRecords[index].branches = signalRecords[index].branches.map { branch in
                if let reason = report.rejected[branch.target] {
                    return .init(
                        target: branch.target, phase: reason == "inputBusy" ? .suppressed : .rejected, reason: reason)
                }
                return .init(target: branch.target, phase: .accepted)
            }
            signalRecords[index].phase =
                report.rejected.isEmpty
                ? .accepted
                : (report.rejected.values.allSatisfy { $0 == "inputBusy" }
                    ? .suppressed : (report.delivered.isEmpty ? .rejected : .partial))
        } else if let phase {
            signalRecords[index].phase = phase
            signalRecords[index].reason = reason.map { String($0.prefix(512)) }
            signalRecords[index].branches = signalRecords[index].branches.map {
                .init(target: $0.target, phase: phase, reason: reason)
            }
        }
        signalRecords[index].updatedAt = .now
        let current = signalRecords[index]
        taskChanged(current)
        if current.aggregates,
            let prior = signalRecords[..<index].lastIndex(where: {
                $0.aggregates && $0.contract == current.contract && $0.source == current.source
                    && $0.mode == current.mode
                    && $0.sessionID == current.sessionID && $0.taskScope == current.taskScope
                    && $0.phase == current.phase && $0.branches == current.branches && $0.reason == current.reason
                    && current.updatedAt.timeIntervalSince($0.time) < 1
            })
        {
            signalRecords[prior].count += current.count
            signalRecords[prior].updatedAt = current.updatedAt
            signalRecords.remove(at: index)
        }
        signalChanged()
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
    /// One-way external facts. Receiver outcomes belong to diagnostics, never to the publisher.
    public func publish(_ input: AgentInput) async throws {
        do {
            try validateExternal(input)
            guard let policy else { throw CommunicationError.unsupportedContract }
            try await publishInternal(input, targets: policy.destinations(for: input).map { ($0, nil) })
        } catch {
            let id = beginSignal(input, mode: .publish, targets: [])
            finishSignal(id, phase: .rejected, reason: String(describing: error))
            throw error
        }
    }

    func publishInternal(
        _ input: AgentInput, targets: [(AgentID, UUID?)],
        observe: (@Sendable (AgentInput) async -> Void)? = nil
    ) async throws {
        let traceID = beginSignal(input, mode: .publish, targets: targets.map(\.0))
        do {
            try Task.checkCancellation()
            let branches = targets.count + (observe == nil ? 0 : 1)
            let bytes = try validatePayload(input) * branches
            if input.metadata.origin == .external {
                guard (policy?.externalSources ?? []).contains(input.metadata.source) else {
                    throw CommunicationError.unauthorized
                }
            }
            guard !closed else { throw CommunicationError.scopeClosed }
            guard branches > 0 else {
                finishSignal(traceID, phase: .unobserved)
                return
            }
            guard targets.count <= 16, Set(targets.map(\.0)).count == targets.count,
                publications.count < 128, publicationBranches + branches <= 256,
                publicationBytes + bytes <= 8 * 1024 * 1024
            else {
                finishSignal(traceID, phase: .dropped, reason: "Publication capacity exceeded")
                return
            }
            let id = UUID()
            publicationBranches += branches
            publicationBytes += bytes
            publications[id] = Task {
                defer {
                    publications[id] = nil
                    publicationBranches -= branches
                    publicationBytes -= bytes
                }
                async let observation: Void = {
                    if let observe { await observe(input) }
                }()
                do {
                    let report: DeliveryReport
                    if targets.isEmpty {
                        finishSignal(traceID, phase: .unobserved)
                        report = DeliveryReport()
                    } else {
                        report = try await deliver(input, targets: targets, traceID: traceID)
                    }
                    for (target, reason) in report.rejected {
                        // Expected paused media admission is suppression, not an execution issue.
                        if reason != "inputBusy" { await publicationFailure(input, target, reason) }
                    }
                } catch is CancellationError {
                    finishSignal(traceID, phase: .dropped, reason: "Publication cancelled")
                } catch {
                    finishSignal(traceID, phase: .rejected, reason: String(describing: error))
                    await publicationFailure(input, nil, String(describing: error))
                }
                await observation
            }
        } catch {
            finishSignal(traceID, phase: .rejected, reason: String(describing: error))
            throw error
        }
    }

    /// Runtime/test cleanup barrier; producers never use this as publication acknowledgment.
    public func flushPublications() async {
        let pending = Array(publications.values)
        for operation in pending { await operation.value }
    }
    public func shutdown() async {
        closed = true
        let pending = Array(publications.values)
        for operation in pending { operation.cancel() }
        for operation in pending { await operation.value }
        for observer in signalObservers.values { observer.finish() }
        signalObservers.removeAll()
        for observer in taskObservers.values { observer.finish() }
        taskObservers.removeAll()
    }
    /// Explicit opt-in for isolated legacy hosts; production external inputs are subscription-only.
    public func send(_ input: AgentInput, to target: AgentID) async throws -> DeliveryReport {
        guard allowsExternalSend else { throw CommunicationError.unauthorized }
        try validateExternal(input)
        return try await deliver(input, targets: [(target, nil)])
    }
    private func validateExternal(_ input: AgentInput) throws {
        guard input.taskScope == nil else { throw CommunicationError.unauthorized }
        if case .observation(let message) = input.payload, message.content(as: AgentTaskSignal.self) != nil {
            throw CommunicationError.unauthorized
        }
        guard input.metadata.origin == .external, input.metadata.incarnation == nil else {
            throw CommunicationError.unauthorized
        }
        switch input.payload {
        case .communicationReceipt, .toolResult, .actionResult, .roundResult, .activityEvent:
            throw CommunicationError.unauthorized
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
            turn: envelope.turn, taskScope: envelope.taskScope)
        return try await deliver(input, targets: [(owner.agent, owner.incarnation)])
    }

    func deliverRoundResult(_ result: GenerationRoundResult, owner: ExecutionOwner, envelope: OutputEnvelope)
        async throws
    {
        guard envelope.roundID == result.roundID else { throw CommunicationError.invalidPayload }
        let outcome = await deliverFeedback(
            .roundResult(result), owner: owner, causality: SignalCausality(envelope: envelope))
        guard outcome == .accepted else { throw CommunicationError.scopeClosed }
    }

    /// Only the stop observer may synthesize this terminal task protocol input.
    func deliverTaskTermination(_ event: AgentTaskTermination) async -> ActionResultDelivery {
        do {
            let signal = try AgentTaskSignal(
                kind: event.requesterStopped ? .cancel : .result,
                scope: event.scope, businessContract: "runtime.taskTermination",
                data: Data(event.reason.utf8),
                status: event.requesterStopped ? nil : .failed)
            let payload = InputPayload.observation(try signal.message())
            return await deliverRuntime(
                AgentInput(
                    sessionID: event.scope.sessionID, payload: payload,
                    metadata: InputMetadata(
                        payload: payload, source: "runtime", origin: .runtime,
                        rootID: event.scope.parentID ?? event.scope.id, parentID: event.scope.id)),
                owner: event.recipient)
        } catch { return .closed }
    }
    /// Runtime completion fact after the child's output/playback barrier; no publisher acknowledgment.
    func deliverReplyCompletion(_ scope: AgentTaskScope) async {
        do {
            let signal = try AgentTaskSignal(
                kind: .progress, scope: scope,
                businessContract: "runtime.replyFinished", data: Data())
            let payload = InputPayload.observation(try signal.message())
            let owner = ExecutionOwner(
                agent: scope.requester,
                incarnation: try await manager.identity(scope.requester), sessionID: scope.sessionID)
            _ = await deliverRuntime(
                AgentInput(
                    sessionID: scope.sessionID, payload: payload,
                    metadata: InputMetadata(payload: payload, source: "runtime", origin: .runtime)), owner: owner)
        } catch {}
    }

    func deliverCommunicationReceipt(_ result: CommunicationReceipt) async throws {
        let outcome = await deliverFeedback(
            .communicationReceipt(result), owner: result.owner, causality: result.causality)
        guard outcome == .accepted else { throw CommunicationError.scopeClosed }
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
                parentID: causality.inputID, hops: causality.hops + 1), turn: causality.turn,
            taskScope: causality.taskScope)
        return await deliverRuntime(input, owner: owner)
    }

    private func deliverRuntime(_ input: AgentInput, owner: ExecutionOwner) async -> ActionResultDelivery {
        let traceID = beginSignal(input, mode: .feedback, targets: [owner.agent])
        do {
            try await manager.validate(owner.agent, incarnation: owner.incarnation, sessionID: owner.sessionID)
            let agent = try await manager.agent(owner.agent)
            guard agent.descriptor.inputs.contains(input.payload.kind),
                policy?.accepts(input, target: owner.agent) ?? true
            else { throw CommunicationError.unsupportedContract }
        } catch {
            finishSignal(traceID, phase: .rejected, reason: String(describing: error))
            return .closed
        }
        do {
            let report = try await deliver(input, targets: [(owner.agent, owner.incarnation)], traceID: traceID)
            if report.rejected.isEmpty { return .accepted }
            do {
                try await manager.validate(owner.agent, incarnation: owner.incarnation, sessionID: owner.sessionID)
            } catch { return .closed }
            return .retry
        } catch CommunicationError.capacityExceeded { return .retry } catch { return .closed }
    }

    private func deliver(_ input: AgentInput, targets: [(AgentID, UUID?)], traceID: UUID? = nil) async throws
        -> DeliveryReport
    {
        let mode: SignalTraceRecord.Mode = input.metadata.origin == .runtime ? .feedback : .send
        let id = traceID ?? beginSignal(input, mode: mode, targets: targets.map(\.0))
        do {
            let report = try await admit(input, targets: targets)
            finishSignal(id, report: report)
            return report
        } catch {
            finishSignal(id, phase: .rejected, reason: String(describing: error))
            throw error
        }
    }
    private func admit(_ input: AgentInput, targets: [(AgentID, UUID?)]) async throws -> DeliveryReport {
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
