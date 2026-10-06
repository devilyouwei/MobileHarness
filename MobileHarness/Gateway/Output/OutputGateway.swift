import ActionRuntime
import AgentCore
import Foundation

/// Validates, routes and dispatches output while preserving the existing execution contract.
public actor OutputGateway {
    public typealias Sink = @Sendable (OutputEnvelope) async -> Void
    private var failures: [OutputFailureRecord] = []
    private var failureRevision: UInt64 = 0
    private var evictedFailures: UInt64 = 0
    private var failureObservers: [UUID: AsyncStream<OutputFailureSnapshot>.Continuation] = [:]
    private var closed = false
    public enum ObservationError: Error { case capacityExceeded }
    public func observeFailures() throws -> AsyncStream<OutputFailureSnapshot> {
        guard failureObservers.count < 8 else { throw ObservationError.capacityExceeded }
        let id = UUID()
        let pair = AsyncStream<OutputFailureSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.yield(failureSnapshot())
        if closed {
            pair.continuation.finish()
        } else {
            failureObservers[id] = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in
                Task { await self?.removeFailureObserver(id) }
            }
        }
        return pair.stream
    }
    private func removeFailureObserver(_ id: UUID) { failureObservers.removeValue(forKey: id) }
    private func failureSnapshot() -> OutputFailureSnapshot {
        .init(revision: failureRevision, records: failures, evictedCount: evictedFailures)
    }
    private func recordFailure(_ envelope: OutputEnvelope, message: String, code: ToolResponse.FailureCode?) {
        let title: String
        switch envelope.output {
        case .toolCall(let call): title = call.toolPath
        case .actionCall(let call): title = call.actionPath.description
        case .rejectedCall(let rejection): title = rejection.alias
        default: title = "Output"
        }
        if failures.count == 100 {
            failures.removeFirst()
            evictedFailures &+= 1
        }
        failures.append(.init(source: envelope.source, title: title, message: message, failureCode: code?.rawValue))
        failureRevision &+= 1
        let snapshot = failureSnapshot()
        for observer in failureObservers.values { observer.yield(snapshot) }
    }
    private var outputResults: [OutputExecutionResult] = []
    private var evictedOutputs: UInt64 = 0
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
    private let resources: ResourceCoordinator?
    private let actionFeedback: ActionFeedback
    private let lifecycleObserverID = UUID()
    private var lifecycleBound = false

    public init(
        manager: AgentManager, requests: InputGateway, tools: ToolRegistry,
        actions: ChannelScheduler = ChannelScheduler(registry: ActionRegistry()),
        policy: CommunicationPolicy? = nil,
        actionFeedback: ActionFeedback = .failuresOnly,
        observedContracts: Set<String> = [],
        observeEvent: (@Sendable (AgentInput) async throws -> Void)? = nil,
        sink: @escaping Sink
    ) {
        self.requests = requests
        self.resources = actions.resourceCoordinator
        self.actionFeedback = actionFeedback
        self.policy = policy
        self.observedContracts = observedContracts
        self.observeEvent = observeEvent
        self.manager = manager
        self.tools = ToolDispatcher(
            registry: tools, input: requests, resources: actions.resourceCoordinator, scheduler: actions)
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
        _ observation: AgentMessage, parent: AgentInput, source: AgentID,
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
        _ = try policy.contracts.validatedSize(observation)
        guard let contract = policy.contracts[observation.contract] else {
            throw CommunicationError.unsupportedContract
        }
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
        // These commands are newly produced work, not forwarded sensor observations. Their
        // admission deadline starts now; the accepted input may outlive its original routing TTL.
        let generatedCommand = contract.startsNewWork
        guard (0..<8).contains(parent.metadata.hops) else { throw CommunicationError.hopLimitExceeded }
        guard generatedCommand || !parent.metadata.expired else { throw CommunicationError.expired }
        sequences[source, default: 0] += 1
        let payload = InputPayload.observation(observation)
        let input = AgentInput(
            sessionID: parent.sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: source.rawValue, incarnation: incarnation, origin: .agent,
                capturedAt: parent.metadata.capturedAt, sequence: sequences[source]!, rootID: parent.metadata.rootID,
                parentID: parent.id, hops: parent.metadata.hops + 1,
                deadline: min(
                    generatedCommand ? .now.advanced(by: .seconds(contract.lifetime)) : parent.metadata.deadline,
                    .now.advanced(by: .seconds(contract.lifetime)))),
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

    private func bindLifecycle() async throws {
        guard !lifecycleBound else { return }
        let scheduler = actions.executor
        let resources = self.resources
        try await manager.observeStops(id: lifecycleObserverID) { agent, incarnation in
            async let jobs: Void = scheduler.cancel(agent: agent, incarnation: incarnation)
            await resources?.close(agent: agent, incarnation: incarnation)
            await jobs
        }
        lifecycleBound = true
    }

    private func executionOwner(_ envelope: OutputEnvelope) async throws -> ExecutionOwner {
        try await bindLifecycle()
        let identity = try await manager.identity(envelope.source)
        try await manager.validate(envelope.source, incarnation: identity, sessionID: envelope.sessionID)
        return ExecutionOwner(agent: envelope.source, incarnation: identity, sessionID: envelope.sessionID)
    }

    public func resourceControl(for source: AgentID, sessionID: UUID) async throws -> ResourceControl {
        try await bindLifecycle()
        guard let resources else { throw ResourceError.unknownResource }
        let owner = ExecutionOwner(agent: source, incarnation: try await manager.identity(source), sessionID: sessionID)
        try await manager.validate(source, incarnation: owner.incarnation, sessionID: sessionID)
        let manager = self.manager
        let scheduler = actions.executor
        return ResourceControl(
            acquire: { ids, duration in
                try await manager.validate(source, incarnation: owner.incarnation, sessionID: sessionID)
                let lease = try await resources.acquire(resources: ids, owner: owner, duration: duration) {
                    await scheduler.cancel(resources: $0)
                }
                do {
                    try Task.checkCancellation()
                    try await manager.validate(source, incarnation: owner.incarnation, sessionID: sessionID)
                    return lease
                } catch {
                    do { try await resources.release(lease, owner: owner) } catch {}
                    throw error
                }
            },
            renew: { lease, duration in
                try await manager.validate(source, incarnation: owner.incarnation, sessionID: sessionID)
                return try await resources.renew(lease, owner: owner, duration: duration)
            },
            release: { lease in try await resources.release(lease, owner: owner) })
    }

    public func cancel(sessionID: UUID) async {
        async let cancelled: Void = actions.cancel(sessionID: sessionID)
        await resources?.close(sessionID: sessionID)
        await cancelled
    }
    public func shutdown() async {
        closed = true
        for observer in failureObservers.values { observer.finish() }
        failureObservers.removeAll()
        async let cancelled: Void = actions.shutdown()
        await resources?.shutdown()
        await cancelled
        await manager.removeStopObserver(lifecycleObserverID)
    }

    /// Production consumers isolate ordinary output failures; explicit cancellation still joins cleanup.
    @discardableResult
    public func execute(_ envelope: OutputEnvelope) async throws -> OutputExecutionResult {
        let failure: String?
        var code: ToolResponse.FailureCode?
        var tool: ToolResponse?
        do {
            tool = try await dispatch(envelope)
            failure = tool?.deliveryFailure
            code = failure == nil ? nil : .deliveryFailed
        } catch {
            try Task.checkCancellation()
            if let producer = error as? any ToolExecutionFailureProviding {
                code = producer.toolFailureCode
            } else if let producer = error as? any ActionExecutionFailureProviding {
                code = .init(rawValue: producer.actionExecutionFailure.rawValue)
            } else if let resource = error as? ResourceError {
                code = resource == .unauthorized ? .permissionDenied : .resourceUnavailable
            } else if error as? CommunicationError == .unauthorized {
                code = .permissionDenied
            } else if let harness = error as? HarnessError,
                [HarnessError.forbiddenOutput, .forbiddenFunction, .forbiddenTool].contains(harness)
            {
                code = .permissionDenied
            } else {
                code = .handlerFailed
            }
            failure = String(
                ((error as? any LocalizedError)?.errorDescription ?? String(describing: error)).prefix(512))
        }
        let result = OutputExecutionResult(
            source: envelope.source, inputID: envelope.inputID,
            sequence: envelope.sequence, tool: tool, failure: failure, failureCode: code)
        if outputResults.count == 256 {
            outputResults.removeFirst()
            evictedOutputs += 1
        }
        outputResults.append(result)
        if result.isError {
            let reasons = [tool?.isError == true ? tool?.value : nil, failure].compactMap { $0 }
            recordFailure(
                envelope, message: reasons.isEmpty ? "Execution failed" : reasons.joined(separator: "\n"),
                code: code ?? tool?.failureCode)
        }
        return result
    }
    public func executionResults(source: AgentID? = nil, inputID: UUID? = nil) async -> OutputExecutionSnapshot {
        let snapshot = await actions.executor.executionSnapshot()
        let matchingOutputs = outputResults.filter {
            (source == nil || $0.source == source) && (inputID == nil || $0.inputID == inputID)
        }
        let matchingActions = snapshot.records.filter {
            (source == nil || $0.source == source) && (inputID == nil || $0.inputID == inputID)
        }
        return OutputExecutionSnapshot(
            outputs: matchingOutputs,
            actions: ActionExecutionSnapshot(
                revision: snapshot.revision, records: matchingActions, evictedCount: snapshot.evictedCount),
            evictedOutputs: evictedOutputs)
    }

    /// Admission is not playback completion. The terminal control joins accepted actions.
    @discardableResult
    public func dispatch(_ envelope: OutputEnvelope) async throws -> ToolResponse? {
        var toolResult: ToolResponse?
        try Task.checkCancellation()
        let descriptor = try await manager.agent(envelope.source).descriptor
        try Task.checkCancellation()
        do { try OutputValidator.validate(envelope.output, descriptor: descriptor) } catch {
            await actions.cancel(envelope)
            throw error
        }
        if case .rejectedCall(let rejection) = envelope.output, rejection.kind == .tool {
            return ToolResponse(
                callID: rejection.callID ?? UUID(),
                value: "\(rejection.reason): \(rejection.alias)", isError: true,
                failureCode: rejection.reason == .invalidParameters ? .invalidArguments : .unknownTool)
        }
        switch try ExecutionRouter.route(envelope.output) {
        case .action(let token):
            do {
                try Task.checkCancellation()
                let owner = try await executionOwner(envelope)
                let required = try actions.executor.requiredResources(for: token)
                let lease = await resources?.lease(for: owner, resources: required)
                try await actions.dispatch(
                    token, envelope: envelope, owner: owner,
                    feedback: descriptor.inputs.contains(.actionResult) ? actionFeedback : .none, lease: lease)
            } catch {
                // Invocation/availability failures reject only this call. Lifecycle and
                // structural scheduling failures still close the owning Action tree.
                if error is ActionSchedulingError || Task.isCancelled || error is CommunicationError {
                    await actions.cancel(envelope)
                }
                throw error
            }
        case .scheduling(let directive):
            do { try await actions.schedule(directive, envelope: envelope) } catch {
                await actions.cancel(envelope)
                throw error
            }
        case .tool(let call):
            toolResult = try await tools.dispatch(call, envelope: envelope, owner: executionOwner(envelope))
        case .finish:
            do { try await actions.finish(envelope) } catch {
                await actions.cancel(envelope)
                throw error
            }
        case .cancel:
            await actions.cancel(envelope)
        case .observe: break
        }
        try Task.checkCancellation()
        await sink(envelope)
        return toolResult
    }
}
