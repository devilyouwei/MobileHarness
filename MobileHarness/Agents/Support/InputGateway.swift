import AgentCore
import Foundation
import FunctionContracts
import Gateway

/// Agents-side adapter for internal Signals: role policy, authenticated endpoints, requests, events and Action feedback delivery to roles.
public actor InputGateway {

    private var signalRecords: [SignalTraceRecord] = []
    private var signalRevision: UInt64 = 0
    private var signalEvictions: UInt64 = 0
    private var signalObservers: [String: AsyncStream<SignalTraceSnapshot>.Continuation] = [:]
    private var taskRecords: [SignalTraceRecord] = []
    private var taskRevision: UInt64 = 0
    private var taskEvictions: UInt64 = 0
    private var taskObservers: [String: AsyncStream<SignalTraceSnapshot>.Continuation] = [:]
    private let signalAggregation: @Sendable (AgentInput) -> Bool
    private let signalSummary: @Sendable (AgentInput) -> String
    private var eventFacility: SignalEventTransport?
    private var eventPublishers: [SignalEndpoint: [String: SignalEventPublisher<AgentInput>]] = [:]
    private var closed = false
    private let publicationFailure: @Sendable (AgentInput, AgentID?, String) async -> Void
    private let publicationSettled: @Sendable (AgentInput, Set<AgentID>, [AgentID: String]) async -> Void
    private var activeAdmissions = 0
    private var activeBranches = 0
    private var observationBytes = 0
    private let policy: CommunicationPolicy?
    private let admission: GatewayAdmission?
    private let manager: AgentManager
    private let requestImplementations: [AgentID: [AgentRequestImplementation]]
    private let eventImplementations: [AgentID: [AgentEventImplementation]]
    private let signals: SignalTransport
    public init(
        manager: AgentManager, policy: CommunicationPolicy? = nil, signals: SignalTransport,
        requestImplementations: [AgentID: [AgentRequestImplementation]] = [:],
        eventImplementations: [AgentID: [AgentEventImplementation]] = [:],
        signalAggregation: @escaping @Sendable (AgentInput) -> Bool = {
            [.audio, .image, .activityEvent].contains($0.payload.kind)
        },
        signalSummary: @escaping @Sendable (AgentInput) -> String = { _ in "" },
        publicationFailure: @escaping @Sendable (AgentInput, AgentID?, String) async -> Void = { _, _, _ in },
        publicationSettled: @escaping @Sendable (AgentInput, Set<AgentID>, [AgentID: String]) async -> Void = {
            _, _, _ in
        },
        admission: GatewayAdmission? = nil
    ) {
        self.requestImplementations = requestImplementations
        self.eventImplementations = eventImplementations
        self.signals = signals
        self.admission = admission
        self.signalAggregation = signalAggregation
        self.signalSummary = signalSummary
        self.publicationFailure = publicationFailure
        self.publicationSettled = publicationSettled
        self.policy = policy
        self.manager = manager
    }

    private var requestBindings: [AgentID: (SignalEndpoint, Task<Void, any Error>)] = [:]
    @discardableResult func bindEndpoint(_ agent: any Agent, incarnation: String) async throws -> SignalEndpoint {
        let id = agent.descriptor.id
        let port = try await signals.register(address: id.rawValue, incarnation: incarnation) {
            [weak self, manager] signal in
            guard let self else { throw CommunicationError.scopeClosed }
            guard let value = signal.payload as? AgentInput else { throw CommunicationError.invalidPayload }
            _ = try await self.validatePayload(value)
            if let source = signal.source {
                guard value.metadata.origin == .agent, value.metadata.source == source.address,
                    value.metadata.incarnation == source.incarnation
                else { throw CommunicationError.unauthorized }
                try await manager.validate(
                    .init(rawValue: source.address), incarnation: source.incarnation, sessionID: value.sessionID)
            } else {
                guard value.metadata.origin == .runtime else { throw CommunicationError.unauthorized }
            }
            try await manager.validate(id, incarnation: incarnation, sessionID: value.sessionID)
            guard agent.descriptor.inputs.contains(value.payload.kind) else { throw HarnessError.unsupportedInput }
            if value.metadata.origin == .agent,
                let implementation = self.eventImplementations[id]?.first(where: {
                    $0.protocolID == value.metadata.contract && $0.channel == value.metadata.topic
                })
            {
                try await implementation.handle(agent, value)
            } else {
                try await agent.receive(value)
            }
        }
        if let existing = requestBindings[id], existing.0 == port {
            try await existing.1.value
            return port
        }
        let enabled = policy?.agents[id]?.requests ?? []
        let declaration = policy?.agents[id]
        let task = Task { [signals] in
            for protocolID in enabled {
                let descriptor = try Self.requestDescriptor(protocolID)
                try await signals.registerContextualRequest(descriptor, endpoint: port) { request, context in
                    let input = request.input
                    guard context.source.address == input.metadata.source,
                        context.source.incarnation == input.metadata.incarnation,
                        input.metadata.origin == .agent, input.metadata.contract == context.protocolID
                    else { throw CommunicationError.unauthorized }
                    _ = try await self.validatePayload(input)
                    try await self.manager.validate(
                        .init(rawValue: context.source.address), incarnation: context.source.incarnation,
                        sessionID: input.sessionID)
                    try await self.manager.validate(id, incarnation: incarnation, sessionID: input.sessionID)
                    if let implementation = self.requestImplementations[id]?.first(where: {
                        $0.protocolID == protocolID
                    }) {
                        return try await implementation.handle(agent, request)
                    }
                    return try await agent.receiveRequest(request)
                }
            }
            if let declaration {
                let bus = try await eventBus()
                for publication in declaration.publications {
                    let descriptor = try eventDescriptor(publication.protocol)
                    let publisher = try await bus.registerProducer(
                        endpoint: port, channel: EventChannel(publication.channel), using: descriptor)
                    eventPublishers[port, default: [:]][publication.channel] = publisher
                }
                for subscription in declaration.subscriptions {
                    _ = try await bus.subscribe(
                        endpoint: port, channel: EventChannel(subscription.channel),
                        using: eventDescriptor(subscription.protocol), sources: Set(subscription.sources),
                        variants: subscription.events.map(Set.init))
                }
            }
        }
        requestBindings[id] = (port, task)
        do { try await task.value } catch {
            await signals.unregister(port)
            if requestBindings[id]?.0 == port { requestBindings[id] = nil }
            eventPublishers[port] = nil
            throw error
        }
        return port
    }
    private func eventBus() async throws -> SignalEventTransport {
        if let eventFacility { return eventFacility }
        let bus = try await signals.events()
        eventFacility = bus
        return bus
    }
    private func eventDescriptor(_ protocolID: String) throws -> SignalEventProtocol<AgentInput> {
        guard let contracts = policy?.contracts, let definition = contracts[protocolID], definition.channel != nil
        else {
            throw CommunicationError.unsupportedContract
        }
        return try .init(
            id: protocolID, variants: definition.events, maximumBytes: definition.maximumBytes,
            measure: { input in
                guard case .observation(let message) = input.payload, message.contract == protocolID else {
                    throw CommunicationError.invalidPayload
                }
                return try contracts.validatedSize(message)
            },
            variant: { input in
                if case .observation(let message) = input.payload { return message.event }
                return nil
            })
    }
    private static func requestDescriptor(_ protocolID: String) throws -> SignalRequestProtocol<
        AgentProtocolRequest, AgentRequestReply
    > {
        try .init(
            id: protocolID, maximumRequestBytes: 262_144, maximumReplyBytes: 4096,
            requestSize: { request in
                let input = request.input
                guard case .observation(let message) = input.payload else { throw CommunicationError.invalidPayload }
                return try message.validatedSize()
            }, replySize: { try JSONEncoder().encode($0).count })
    }
    func retireEndpoint(_ id: AgentID, incarnation: String) async {
        await signals.unregister(address: id.rawValue, incarnation: incarnation)
        if let binding = requestBindings[id], binding.0.incarnation == incarnation {
            eventPublishers[binding.0] = nil
            requestBindings[id] = nil
        }
    }

    public func observeSignals() throws -> AsyncStream<SignalTraceSnapshot> {
        guard signalObservers.count + taskObservers.count < 8 else { throw CommunicationError.capacityExceeded }
        let id = UUID().uuidString
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
        let id = UUID().uuidString
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
    private func removeTaskObserver(_ id: String) { taskObservers[id] = nil }
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
    private func removeSignalObserver(_ id: String) { signalObservers[id] = nil }
    private func signalSnapshot() -> SignalTraceSnapshot {
        .init(revision: signalRevision, records: signalRecords, evictedCount: signalEvictions)
    }
    private func signalChanged() {
        signalRevision &+= 1
        let snapshot = signalSnapshot()
        for observer in signalObservers.values { observer.yield(snapshot) }
    }
    private func beginSignal(_ input: AgentInput, mode: SignalTraceRecord.Mode, targets: [AgentID]) -> String {
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

    /// Records joined execution cleanup for observers without admitting another Agent input.
    func recordTaskRetirement(_ evidence: AgentMessage, owner: ExecutionOwner) {
        guard !closed else { return }
        let payload = InputPayload.observation(evidence)
        let id = UUID().uuidString
        let input = AgentInput(
            id: id, sessionID: owner.sessionID, payload: payload,
            metadata: .init(
                payload: payload, source: owner.agent.rawValue, incarnation: owner.incarnation, origin: .runtime,
                rootID: id))
        finishSignal(beginSignal(input, mode: .feedback, targets: []), phase: .accepted)
    }
    private func finishSignal(
        _ id: String, phase: SignalTraceRecord.Phase? = nil, reason: String? = nil,
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
            let targets = Set(signalRecords[index].branches.map(\.target))
                .union(report.delivered).union(report.rejected.keys)
            signalRecords[index].branches = targets.sorted { $0.rawValue < $1.rawValue }.prefix(16).map { target in
                if let reason = report.rejected[target] {
                    return .init(
                        target: target, phase: reason == "inputBusy" ? .suppressed : .rejected, reason: reason)
                }
                return .init(target: target, phase: .accepted)
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

    /// The requesting owner explicitly creates and retains this generic subscription handle.
    func subscribe(_ filter: AgentEventFilter, consumer: AgentID, incarnation: String) async throws
        -> AgentEventSubscription
    {
        guard !closed, let definition = policy?.contracts[filter.protocolID], definition.channel == filter.channel,
            !filter.sources.isEmpty, !filter.sessionID.isEmpty
        else { throw CommunicationError.unsupportedContract }
        guard try await manager.identity(consumer) == incarnation else { throw CommunicationError.unauthorized }
        let role = try await manager.agent(consumer)
        let port = try await bindEndpoint(role, incarnation: incarnation)
        let bus = try await eventBus()
        let subscription = try await bus.subscribe(
            endpoint: port, channel: EventChannel(filter.channel),
            using: eventDescriptor(filter.protocolID), sources: Set(filter.sources.map(\.rawValue)),
            scope: filter.scope, sessionID: filter.sessionID)
        return AgentEventSubscription(cancel: { await bus.cancel(subscription) })
    }

    // Module-internal: only OutputGateway supplies resolved targets and a bound source identity.
    func sendInternal(_ input: AgentInput, targets: [(AgentID, String)]) async throws -> DeliveryReport {
        guard input.metadata.origin == .agent, input.metadata.incarnation != nil else {
            throw CommunicationError.unauthorized
        }
        return try await deliver(input, targets: targets.map { ($0.0, Optional($0.1)) })
    }
    private func validatePayload(_ input: AgentInput) throws -> Int {
        guard !closed else { throw CommunicationError.scopeClosed }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        guard input.metadata.contract == InputMetadata(payload: input.payload, rootID: input.metadata.rootID).contract,
            input.metadata.version == 1, input.metadata.hops >= 0, input.metadata.hops <= 8,
            input.metadata.capturedAt.isFinite, input.metadata.capturedAt >= 0
        else { throw CommunicationError.invalidPayload }
        switch input.metadata.origin {
        case .local: throw CommunicationError.unauthorized
        case .agent:
            guard input.metadata.incarnation != nil else { throw CommunicationError.unauthorized }
        case .runtime:
            guard input.metadata.source == "runtime", input.metadata.incarnation == nil else {
                throw CommunicationError.unauthorized
            }
        }
        switch input.payload {
        case .actionResult(let result), .executionFeedback(.actionFinished(let result)):
            guard result.owner.sessionID == input.sessionID, result.owner.agent.rawValue.utf8.count <= 64,
                result.path.domain.utf8.count <= 64, result.path.module.utf8.count <= 64,
                result.path.function.utf8.count <= 64,
                result.status != .succeeded || result.completion != nil,
                (result.status == .succeeded) == (result.failure == nil)
            else { throw CommunicationError.invalidPayload }
            if result.status != .succeeded, let completion = result.completion {
                // Failed/cancelled reports retain partial effects; success-only completion kinds are invalid.
                guard case .report = completion else { throw CommunicationError.invalidPayload }
            }
        case .activityEvent(let event):
            guard event.owner.sessionID == input.sessionID, event.owner.agent.rawValue.utf8.count <= 64,
                event.sequence > 0
            else { throw CommunicationError.invalidPayload }
        case .observation(let value): return try (policy?.contracts ?? .standard).validatedSize(value)
        case .text(let value):
            guard value.utf8.count <= 4096 else { throw CommunicationError.invalidPayload }
            return value.utf8.count
        case .event(let value):
            guard value.utf8.count <= 16384 else { throw CommunicationError.invalidPayload }
            return value.utf8.count
        default: break
        }
        return 0
    }
    /// Bound Agent publication retains one-way diagnostics without business acknowledgment.

    func publishInternal(
        _ input: AgentInput,
        observe: (@Sendable (AgentInput) async throws -> Void)? = nil, scope: String? = nil,
        audience: Set<AgentID>? = nil
    ) async throws -> DeliveryReport {
        let traceID = beginSignal(input, mode: .publish, targets: [])
        do {
            _ = try await publishEvent(
                input, observe: observe, scope: scope, audience: audience, traceID: traceID)
            return DeliveryReport(publicationAccepted: true)
        } catch {
            finishSignal(traceID, phase: .rejected, reason: String(describing: error))
            throw error
        }
    }
    private func publishEvent(
        _ input: AgentInput,
        observe: (@Sendable (AgentInput) async throws -> Void)? = nil,
        scope: String?, audience: Set<AgentID>?, traceID: String
    ) async throws -> SignalPublication {
        guard !closed else { throw CommunicationError.scopeClosed }
        try checkAdmission(input)
        try Task.checkCancellation()
        let bytes = try validatePayload(input)
        guard input.metadata.origin == .agent, let incarnation = input.metadata.incarnation,
            let definition = policy?.contracts[input.metadata.contract], let channel = definition.channel
        else { throw CommunicationError.unauthorized }
        let sourceID = AgentID(rawValue: input.metadata.source)
        try await manager.validate(sourceID, incarnation: incarnation, sessionID: input.sessionID)
        let source = try await manager.agent(sourceID)
        let sourcePort = try await bindEndpoint(source, incarnation: incarnation)
        let bus = try await eventBus()
        guard let publisher = eventPublishers[sourcePort]?[channel] else {
            throw CommunicationError.unauthorized
        }
        let initialFailures: [AgentID: String] = [:]
        let observer: (@Sendable () async throws -> Void)?
        if let observe { observer = { try await observe(input) } } else { observer = nil }
        let cleanup =
            input.metadata.origin == .runtime
            || {
                if case .observation(let message) = input.payload { return message.taskSignal?.kind == .result }
                return false
            }()
        return try await bus.publish(
            input, from: publisher,
            envelope: .init(
                id: input.id, sessionID: input.sessionID, contract: input.metadata.contract, channel: channel,
                version: input.metadata.version, hops: input.metadata.hops, payloadBytes: bytes,
                expiresAt: input.metadata.deadline, cleanup: cleanup,
                control: AgentContracts.isControlContract(input.metadata.contract)),
            scope: scope, audience: audience.map { Set($0.map(\.rawValue)) }, observer: observer
        ) { [self] results in
            await settlePublication(input, traceID: traceID, results: results, initialFailures: initialFailures)
        }
    }
    private func settlePublication(
        _ input: AgentInput, traceID: String, results: [SignalEventBranchResult], initialFailures: [AgentID: String]
    ) async {
        var delivered: [AgentID] = []
        var rejected = initialFailures
        for result in results {
            if result.target == "@observer" {
                if result.status != .accepted {
                    await publicationFailure(input, nil, result.reason ?? "Observer closed")
                }
            } else if result.status == .accepted {
                delivered.append(.init(rawValue: result.target))
            } else {
                rejected[.init(rawValue: result.target)] = result.reason ?? result.status.rawValue
            }
        }
        if delivered.isEmpty && rejected.isEmpty {
            finishSignal(traceID, phase: .unobserved)
        } else {
            finishSignal(traceID, report: .init(delivered: delivered, rejected: rejected))
        }
        for (target, reason) in rejected {
            if !["inputBusy", "notRunning"].contains(reason) || input.metadata.contract == "agent.interruption.v1"
                || {
                    if case .observation(let message) = input.payload { return message.event == "final" }
                    return false
                }()
            {
                await publicationFailure(input, target, reason)
            }
        }
        await publicationSettled(input, Set(delivered), rejected)
    }

    private func checkAdmission(_ input: AgentInput) throws {
        guard let admission, !admission.isOpen else { return }
        if input.metadata.origin == .runtime { return }
        if case .observation(let message) = input.payload, let signal = message.content(as: AgentTaskSignal.self),
            signal.kind == .cancel || signal.kind == .result
        {
            return
        }
        try admission.check()
    }
    func suspend() async {
        await eventFacility?.cancelPublications(sources: Set(requestBindings.values.map { $0.0 }))
    }
    /// Runtime/test barrier; publication callers receive admission only.
    public func flushPublications() async { await eventFacility?.flush() }
    public func shutdown() async {
        closed = true
        await eventFacility?.cancelPublications(sources: Set(requestBindings.values.map { $0.0 }), includeCleanup: true)
        for observer in signalObservers.values { observer.finish() }
        signalObservers.removeAll()
        for observer in taskObservers.values { observer.finish() }
        taskObservers.removeAll()
    }

    /// Module-internal: returning Tools bind the original execution owner, never public external admission.
    func deliverToolResult(_ result: ToolResult, owner: ExecutionOwner, envelope: OutputEnvelope) async throws {
        guard owner.agent == envelope.source, owner.sessionID == envelope.sessionID else {
            throw CommunicationError.unauthorized
        }
        let agent = try await manager.agent(owner.agent)
        guard agent.descriptor.inputs.contains(.toolResult) else { return }
        let input = try envelope.toolFeedbackInput(result)
        try await receiveExecutionInput(input, owner: owner, agent: agent, retryHandlerFailure: false)
    }

    func deliverExecutionFeedback(_ feedback: ExecutionFeedback, owner: ExecutionOwner, causality: SignalCausality)
        async throws
    {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        repeat {
            switch await deliverFeedback(.executionFeedback(feedback), owner: owner, causality: causality) {
            case .accepted: return
            case .closed: throw CommunicationError.scopeClosed
            case .retry: try await clock.sleep(for: .milliseconds(20))
            }
        } while clock.now < deadline
        throw CommunicationError.capacityExceeded
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
                    id: UUID().uuidString,
                    sessionID: event.scope.sessionID, payload: payload,
                    metadata: InputMetadata(
                        payload: payload, source: "runtime", origin: .runtime,
                        rootID: event.scope.parentID ?? event.scope.id, parentID: event.scope.id)),
                owner: event.recipient)
        } catch { return .closed }
    }
    private func usesUnifiedActionFeedback(_ agent: any Agent) -> Bool {
        agent.descriptor.inputs.contains(.executionFeedback) && !agent.descriptor.inputs.contains(.actionResult)
    }

    private func usesUnifiedActionFeedback(_ owner: ExecutionOwner) async -> Bool {
        guard let agent = try? await manager.agent(owner.agent) else { return false }
        return usesUnifiedActionFeedback(agent)
    }

    private func actionResultPayload(_ result: ActionResult, unified: Bool) -> InputPayload {
        unified ? .executionFeedback(.actionFinished(result)) : .actionResult(result)
    }

    func receiveActionResult(_ result: ExecutionResult, deadline: ContinuousClock.Instant?) async throws {
        let owner = result.owner
        let causality = result.causality
        guard owner.sessionID == result.envelope.sessionID,
            owner.endpoint == result.envelope.source
        else { throw CommunicationError.unauthorized }
        guard (0..<8).contains(causality.hops) else { throw CommunicationError.hopLimitExceeded }

        let agent = try await manager.agent(owner.agent)
        let input = feedbackInput(
            actionResultPayload(result.agentValue, unified: usesUnifiedActionFeedback(agent)),
            owner: owner, causality: causality, deadline: deadline)
        try await receiveExecutionInput(input, owner: owner, agent: agent)
    }

    /// Complete feedback in Agents once the Actions transport reply has arrived.
    private func receiveExecutionInput(
        _ input: AgentInput, owner: ExecutionOwner, agent: any Agent, retryHandlerFailure: Bool = true
    ) async throws {
        let traceID = beginSignal(input, mode: .feedback, targets: [owner.agent])
        do {
            _ = try validatePayload(input)
            try await manager.validate(owner.agent, incarnation: owner.incarnation, sessionID: owner.sessionID)
            try validateFeedbackReceiver(input, agent: agent)
            try Task.checkCancellation()
        } catch {
            finishSignal(traceID, phase: .rejected, reason: String(describing: error))
            throw error
        }
        do {
            try await agent.receive(input)
        } catch {
            finishSignal(traceID, phase: .rejected, reason: String(describing: error))
            try Task.checkCancellation()
            guard retryHandlerFailure else { throw error }
            try await manager.validate(owner.agent, incarnation: owner.incarnation, sessionID: owner.sessionID)
            guard !closed else { throw CommunicationError.scopeClosed }
            throw CommunicationError.capacityExceeded
        }
        finishSignal(traceID, phase: .accepted)
    }

    public func deliverActionResult(_ result: ActionResult) async -> ActionResultDelivery {
        let payload = actionResultPayload(result, unified: await usesUnifiedActionFeedback(result.owner))
        return await deliverFeedback(payload, owner: result.owner, causality: result.causality)
    }

    func deliverActionStart(_ started: ExecutionStart) async -> ActionResultDelivery {
        guard await usesUnifiedActionFeedback(started.owner) else { return .accepted }
        let causality = (started.envelope.correlation as? SignalCausality) ?? .root(id: started.envelope.inputID)
        return await deliverFeedback(
            .executionFeedback(
                .actionStarted(
                    roundID: started.envelope.roundID, callID: started.envelope.callID,
                    executionID: started.executionID, controlCapabilities: started.controlCapabilities,
                    path: started.path.map { .init(domain: $0.domain, module: $0.module, function: $0.function) })),
            owner: started.owner, causality: causality
        )
    }

    func deliverActionControl(_ control: ActionControlFeedback) async -> ActionResultDelivery {
        let feedback: ExecutionFeedback
        switch control.event {
        case .stateChanged(let change): feedback = .actionStateChanged(change)
        case .receipt(let receipt): feedback = .actionControlReceipt(receipt)
        }
        let causality = (control.envelope.correlation as? SignalCausality) ?? .root(id: control.envelope.inputID)
        return await deliverFeedback(.executionFeedback(feedback), owner: control.owner, causality: causality)
    }

    public func deliverActivityEvent(_ event: ActivityEvent) async -> ActionResultDelivery {
        guard (0..<8).contains(event.causality.hops) else { return .closed }
        return await deliverRuntime(
            feedbackInput(
                .activityEvent(event), owner: event.owner, causality: event.causality, sequence: event.sequence),
            owner: event.owner)
    }

    private func deliverFeedback(
        _ payload: InputPayload, owner: ExecutionOwner, causality: SignalCausality
    ) async -> ActionResultDelivery {
        guard (0..<8).contains(causality.hops) else { return .closed }
        do {
            let agent = try await manager.agent(owner.agent)
            try await receiveExecutionInput(
                feedbackInput(payload, owner: owner, causality: causality), owner: owner,
                agent: agent)
            return .accepted
        } catch CommunicationError.capacityExceeded { return .retry } catch { return .closed }
    }

    private func feedbackInput(
        _ payload: InputPayload, owner: ExecutionOwner, causality: SignalCausality,
        sequence: UInt64? = nil, deadline: ContinuousClock.Instant? = nil
    ) -> AgentInput {
        AgentInput(
            id: UUID().uuidString,
            sessionID: owner.sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "runtime", origin: .runtime,
                sequence: sequence ?? causality.sequence, rootID: causality.rootID,
                parentID: causality.inputID, hops: causality.hops + 1, deadline: deadline), turn: causality.turn,
            taskScope: causality.taskScope)
    }

    private func validateFeedbackReceiver(_ input: AgentInput, agent: any Agent) throws {
        guard agent.descriptor.inputs.contains(input.payload.kind),
            policy?.accepts(input, target: agent.descriptor.id) ?? true
        else { throw CommunicationError.unsupportedContract }
    }

    private func deliverRuntime(_ input: AgentInput, owner: ExecutionOwner) async -> ActionResultDelivery {
        let traceID = beginSignal(input, mode: .feedback, targets: [owner.agent])
        do {
            try await manager.validate(owner.agent, incarnation: owner.incarnation, sessionID: owner.sessionID)
            let agent = try await manager.agent(owner.agent)
            try validateFeedbackReceiver(input, agent: agent)
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

    private func deliver(
        _ input: AgentInput, targets: [(AgentID, String?)], traceID: String? = nil
    ) async throws
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
    private func admit(_ input: AgentInput, targets: [(AgentID, String?)]) async throws
        -> DeliveryReport
    {
        guard !closed else { throw CommunicationError.scopeClosed }
        try checkAdmission(input)
        try Task.checkCancellation()
        let encodedBytes = try validatePayload(input)
        guard !targets.isEmpty else { throw CommunicationError.noRecipients }
        guard targets.count <= 16, Set(targets.map(\.0)).count == targets.count else {
            throw CommunicationError.capacityExceeded
        }

        let retainedBytes = encodedBytes * targets.count
        let control = AgentContracts.isControlContract(input.metadata.contract) || input.metadata.origin == .runtime
        guard activeAdmissions < (control ? 128 : 112), activeBranches + targets.count <= (control ? 256 : 240),
            observationBytes + retainedBytes <= 8 * 1024 * 1024 - (control ? 0 : 256 * 1024)
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
        return try await withThrowingTaskGroup(of: (AgentID, String?, AgentRequestReply?).self) { group in
            for (target, expectedIncarnation) in targets {
                let operation: @Sendable () async throws -> (AgentID, String?, AgentRequestReply?) = {
                    [manager, policy, admission, signals] in
                    do {
                        try Task.checkCancellation()
                        if let policy {
                            let accepted = policy.accepts(input, target: target)
                            guard accepted else { throw CommunicationError.unsupportedContract }
                        }
                        if input.metadata.incarnation != nil, policy == nil {
                            throw CommunicationError.unsupportedContract
                        }
                        let incarnation: String
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
                        if let admission, !admission.isOpen, input.metadata.origin != .runtime {
                            let task: AgentTaskSignal?
                            if case .observation(let message) = input.payload {
                                task = message.content(as: AgentTaskSignal.self)
                            } else {
                                task = nil
                            }
                            if task?.kind != .cancel && task?.kind != .result { try admission.check() }
                        }
                        let targetPort = try await self.bindEndpoint(agent, incarnation: incarnation)
                        let sourcePort: SignalEndpoint?
                        if let sourceIncarnation = input.metadata.incarnation {
                            let source = try await manager.agent(AgentID(rawValue: input.metadata.source))
                            sourcePort = try await signals.register(
                                address: input.metadata.source, incarnation: sourceIncarnation
                            ) { signal in
                                guard let value = signal.payload as? AgentInput else {
                                    throw CommunicationError.invalidPayload
                                }
                                try await source.receive(value)
                            }
                        } else {
                            sourcePort = nil
                        }
                        if input.metadata.origin == .agent,
                            policy?.agents[target]?.requests.contains(input.metadata.contract) == true,
                            let sourcePort
                        {
                            let reply = try await signals.request(
                                source: sourcePort, target: targetPort,
                                using: Self.requestDescriptor(input.metadata.contract),
                                request: try AgentProtocolRequest(
                                    input: input,
                                    operation: {
                                        guard case .observation(let message) = input.payload,
                                            let operation = message.operation
                                        else {
                                            throw CommunicationError.invalidPayload
                                        }
                                        return operation
                                    }()),
                                envelope: SignalEnvelope(
                                    id: input.id, sessionID: input.sessionID,
                                    contract: input.metadata.contract,
                                    channel: policy?.contracts[input.metadata.contract]?.channel,
                                    version: input.metadata.version, hops: input.metadata.hops,
                                    payloadBytes: encodedBytes,
                                    expiresAt: input.metadata.deadline,
                                    control: {
                                        if case .observation(let message) = input.payload {
                                            return message.operation == .cancel
                                        }
                                        return false
                                    }()))
                            guard reply.requestID == input.id else { throw CommunicationError.invalidPayload }
                            return (target, nil, reply)
                        } else {
                            try await signals.send(
                                source: sourcePort, target: targetPort,
                                envelope: SignalEnvelope(
                                    id: input.id, sessionID: input.sessionID, contract: input.metadata.contract,
                                    channel: policy?.contracts[input.metadata.contract]?.channel,
                                    version: input.metadata.version, hops: input.metadata.hops,
                                    payloadBytes: encodedBytes,
                                    expiresAt: input.metadata.deadline,
                                    cleanup: input.metadata.origin == .runtime
                                        || {
                                            guard case .observation(let message) = input.payload,
                                                let task = message.content(as: AgentTaskSignal.self)
                                            else { return false }
                                            return task.kind == .cancel || task.kind == .result
                                        }(), control: AgentContracts.isControlContract(input.metadata.contract)),
                                payload: input)
                        }
                        return (target, nil, nil)
                    } catch {
                        if input.metadata.origin == .agent,
                            policy?.agents[target]?.requests.contains(input.metadata.contract) == true
                        {
                            throw error
                        }
                        return (target, String(describing: error), nil)
                    }
                }
                group.addTask { try await operation() }
            }
            var delivered: [AgentID] = []
            var rejected: [AgentID: String] = [:]
            var reply: AgentRequestReply?
            for try await (id, error, result) in group {
                if let error {
                    rejected[id] = error
                } else {
                    delivered.append(id)
                    if let result { reply = result }
                }
            }
            return DeliveryReport(delivered: delivered, rejected: rejected, reply: reply)
        }
    }
}
