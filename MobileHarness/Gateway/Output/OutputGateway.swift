import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts

/// A producer-bound port; the source cannot select or replace its registration identity.
public struct GatewayOutputConsumer: Sendable {
    private let consume: @Sendable (OutputEnvelope) async throws -> OutputExecutionResult
    fileprivate init(_ consume: @escaping @Sendable (OutputEnvelope) async throws -> OutputExecutionResult) {
        self.consume = consume
    }
    @discardableResult public func execute(_ envelope: OutputEnvelope) async throws -> OutputExecutionResult {
        try await consume(envelope)
    }
}
private enum OutputProducerBinding {
    struct Identity: Sendable {
        let agent: AgentID
        let incarnation: String
    }
    @TaskLocal static var identity: Identity?
}

private enum OutputDispatchOwnership {
    @TaskLocal static var current: String?
}

/// Validates, routes and dispatches output while preserving the existing execution contract.
public actor OutputGateway {
    public typealias Sink = @Sendable (OutputEnvelope) async -> Void
    private var failures: [OutputFailureRecord] = []
    private var failureRevision: UInt64 = 0
    private var evictedFailures: UInt64 = 0
    private var failureObservers: [String: AsyncStream<OutputFailureSnapshot>.Continuation] = [:]
    private var closed = false
    public enum ObservationError: Error { case capacityExceeded }
    public func observeFailures() throws -> AsyncStream<OutputFailureSnapshot> {
        guard failureObservers.count < 8 else { throw ObservationError.capacityExceeded }
        let id = UUID().uuidString
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
    private func removeFailureObserver(_ id: String) { failureObservers.removeValue(forKey: id) }
    private func failureSnapshot() -> OutputFailureSnapshot {
        .init(revision: failureRevision, records: failures, evictedCount: evictedFailures)
    }
    private func recordFailure(_ envelope: OutputEnvelope, message: String, code: ActionExecutionFailureCode?) {
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
        failures.append(
            .init(
                source: envelope.source, title: envelope.failure?.category.rawValue ?? title,
                message: envelope.failure?.detail ?? message, failureCode: envelope.failure?.code ?? code?.rawValue,
                inputID: envelope.inputID, diagnostic: envelope.failure,
                sessionID: envelope.sessionID, roundID: envelope.roundID))
        failureRevision &+= 1
        let snapshot = failureSnapshot()
        for observer in failureObservers.values { observer.yield(snapshot) }
    }
    private struct OutputScope: Hashable, Sendable {
        let source: AgentID
        let session: String
        let input: String
        init(_ envelope: OutputEnvelope) {
            source = envelope.source
            session = envelope.sessionID
            input = envelope.inputID
        }
    }
    private struct ProducerSession: Hashable {
        let source: AgentID
        let session: String
    }
    private struct DirectExecution {
        let scope: OutputScope
        let interruption: Bool
        let task: Task<ToolResponse?, any Error>
    }
    // Same bounded lifetime as admitted input transport; retire only at its terminal boundary.
    private var outputScopes: Set<OutputScope> = []
    private var cancelledScopes: Set<OutputScope> = []
    private var cancellingProducers: Set<ProducerSession> = []
    private var directExecutions: [String: DirectExecution] = [:]
    private func isCancelled(_ scope: OutputScope) -> Bool {
        cancelledScopes.contains(scope)
            || cancellingProducers.contains(.init(source: scope.source, session: scope.session))
    }
    private static func isTerminal(_ output: AgentOutput) -> Bool {
        if case .control(let value) = output {
            return value == "agent.finished" || value == "assistant.finished" || value == "agent.cancelled"
                || value.hasPrefix("agent.error:") || value.hasPrefix("assistant.error:")
        }
        return false
    }
    private static func isInterruption(_ envelope: OutputEnvelope) -> Bool {
        guard envelope.inputMetadata.origin == .external, envelope.inputMetadata.source == "runtime",

            case .communication(let communication) = envelope.output,
            communication.message.content(as: AgentTaskSignal.self)?.kind == .cancel
        else { return false }
        return true
    }
    private func dispatchOwned(_ envelope: OutputEnvelope) async throws -> ToolResponse? {
        switch envelope.output {
        case .toolCall, .communication:
            guard directExecutions.count < 128 else { throw HarnessError.queueFull }
            let id = UUID().uuidString
            let task = Task {
                try await OutputDispatchOwnership.$current.withValue(id) {
                    try await self.dispatch(envelope)
                }
            }
            directExecutions[id] = .init(
                scope: OutputScope(envelope), interruption: Self.isInterruption(envelope), task: task)
            defer { directExecutions[id] = nil }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        default: return try await dispatch(envelope)
        }
    }
    private var roundFailures: [String: String] = [:]
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
    private let lifecycleObserverID = UUID().uuidString
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
            registry: tools, input: requests, resources: actions.resourceCoordinator)
        self.actions = ActionDispatcher(executor: actions)
        self.sink = sink
    }

    public func consumer(for producer: any Agent) async throws -> GatewayOutputConsumer {
        let id = producer.descriptor.id
        let incarnation = try await manager.outputIdentity(for: producer)
        return GatewayOutputConsumer { [self] envelope in
            guard envelope.source == id else { throw CommunicationError.unauthorized }
            try await manager.validate(id, incarnation: incarnation, sessionID: envelope.sessionID)
            return try await OutputProducerBinding.$identity.withValue(.init(agent: id, incarnation: incarnation)) {
                try await execute(envelope)
            }
        }
    }
    private func sourceIdentity(_ envelope: OutputEnvelope) async throws -> String {
        if let bound = OutputProducerBinding.identity {
            guard bound.agent == envelope.source else { throw CommunicationError.unauthorized }
            try await manager.validate(bound.agent, incarnation: bound.incarnation, sessionID: envelope.sessionID)
            return bound.incarnation
        }
        return try await manager.identity(envelope.source)
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
        incarnation: String, target: AgentID?
    ) async throws -> DeliveryReport {
        try await emit(
            observation, inputID: parent.id, sessionID: parent.sessionID,
            metadata: parent.metadata, turn: parent.turn, source: source, incarnation: incarnation, target: target)
    }

    private func emit(
        _ observation: AgentMessage, inputID: String, sessionID: String,
        metadata: InputMetadata, turn: AgentTurn?, source: AgentID, incarnation: String, target: AgentID?
    ) async throws -> DeliveryReport {
        var issuedGrant: (String, String)?
        do {
            try Task.checkCancellation()
            guard let policy, let declaration = policy.agents[source] else {
                throw CommunicationError.unauthorized
            }
            guard emitting[source, default: 0] < 16 else { throw CommunicationError.capacityExceeded }
            emitting[source, default: 0] += 1
            defer { emitting[source, default: 1] -= 1 }
            try await manager.validate(source, incarnation: incarnation, sessionID: sessionID)
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
                guard declaration.publications.contains(observation.contract) else {
                    throw CommunicationError.unauthorized
                }
            }
            // These commands are newly produced work, not forwarded sensor observations. Their
            // admission deadline starts now; the accepted input may outlive its original routing TTL.
            let task = observation.content(as: AgentTaskSignal.self)
            if let task {
                try task.validate()
                let incoming = task.kind == .request || task.kind == .input || task.kind == .cancel
                guard sessionID == task.scope.sessionID,
                    source == (incoming ? task.scope.requester : task.scope.executor),
                    target == (incoming ? task.scope.executor : task.scope.requester)
                else { throw CommunicationError.unauthorized }
                if task.kind == .request {
                    let token = try await manager.grantTask(task.scope, sender: source)
                    issuedGrant = (task.scope.id, token)
                } else {
                    try await manager.validateTask(task.scope, agent: source, sessionID: sessionID)
                    if task.kind == .input { try await manager.validateTaskInput(task.scope, agent: source) }
                    if task.kind == .cancel { try await manager.cancelTask(task.scope, requester: source) }
                    if task.kind == .result {
                        try await manager.beginTaskCompletion(task.scope, executor: source)
                        if task.status != .succeeded {
                            for id in try await manager.taskExecutions(task.scope) {
                                await actions.executor.cancel(inputID: id, source: source)
                            }
                            await cancelTaskCalls(task.scope.id)
                        }
                        for id in try await manager.taskExecutions(task.scope) {
                            do { try await actions.executor.finish(inputID: id, source: source) } catch {
                                if task.status == .succeeded { throw error }
                                try Task.checkCancellation()
                            }
                        }
                        let calls = taskCalls[task.scope.id] ?? [:]
                        for call in calls.values {
                            do { _ = try await call.value } catch {
                                if task.status == .succeeded { throw error }
                                try Task.checkCancellation()
                            }
                        }
                    }
                }
            }
            let generatedCommand = contract.startsNewWork
            guard (0..<8).contains(metadata.hops) else { throw CommunicationError.hopLimitExceeded }
            guard generatedCommand || !metadata.expired else { throw CommunicationError.expired }
            sequences[source, default: 0] += 1
            let payload = InputPayload.observation(observation)
            let input = AgentInput(
                id: UUID().uuidString,
                sessionID: sessionID, payload: payload,
                metadata: InputMetadata(
                    payload: payload, source: source.rawValue, incarnation: incarnation, origin: .agent,
                    capturedAt: metadata.capturedAt, sequence: sequences[source]!, rootID: metadata.rootID,
                    parentID: inputID, hops: metadata.hops + 1,
                    deadline: generatedCommand ? nil : metadata.deadline),
                turn: turn,
                taskScope: task.flatMap {
                    ($0.kind == .request || $0.kind == .input || $0.kind == .cancel) ? $0.scope : nil
                })
            if target == nil {
                let observe: (@Sendable (AgentInput) async -> Void)?
                if observedContracts.contains(observation.contract), let observeEvent {
                    observe = { input in
                        do { try await observeEvent(input) } catch {
                            // Presentation endpoint failure belongs to the observer, never the publisher.
                        }
                    }
                } else {
                    observe = nil
                }
                try await requests.publishInternal(
                    input, targets: policy.destinations(for: input).map { ($0, nil) }, observe: observe)
                return DeliveryReport()
            }
            let destinations = target.map { [$0] } ?? []
            guard !destinations.isEmpty else { throw CommunicationError.noRecipients }
            var targets: [(AgentID, String)] = []
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
            let report = targets.isEmpty ? DeliveryReport() : try await requests.sendInternal(input, targets: targets)
            if let task {
                if task.kind == .result, report.delivered.isEmpty || !report.rejected.isEmpty {
                    await failTaskCompletion(
                        task.scope,
                        owner: ExecutionOwner(agent: source, incarnation: incarnation, sessionID: sessionID),
                        reason: "Final task report rejected")
                } else if task.kind == .result
                    || (task.kind == .request && (report.delivered.isEmpty || !report.rejected.isEmpty))
                {
                    await manager.retireTask(task.scope.id)
                }
            }
            return DeliveryReport(
                delivered: report.delivered, rejected: unavailable.merging(report.rejected) { _, new in new })
        } catch {
            if let issuedGrant { await manager.retireTask(issuedGrant.0, admissionID: issuedGrant.1) }
            throw error
        }
    }

    private func bindLifecycle() async throws {
        guard !lifecycleBound else { return }
        let scheduler = actions.executor
        let resources = self.resources
        let requests = self.requests
        try await manager.observeStops(id: lifecycleObserverID) { [weak self] agent, incarnation, terminations in
            for event in terminations {
                for executionID in event.executionIDs {
                    await scheduler.cancel(inputID: executionID, source: event.scope.executor)
                }
                await self?.cancelTaskCalls(event.scope.id)
                let outcome = await requests.deliverTaskTermination(event)
                await self?.recordTaskTermination(event, outcome: outcome)
            }
            async let jobs: Void = scheduler.cancel(agent: agent, incarnation: incarnation)
            async let direct: Void? = self?.cancelDirectProducer(agent)
            await resources?.close(agent: agent, incarnation: incarnation)
            await direct
            await jobs
        }
        lifecycleBound = true
    }

    private func cancelDirectProducer(_ agent: AgentID) async {
        cancelledScopes.formUnion(outputScopes.filter { $0.source == agent })
        let selected = directExecutions.values.filter { $0.scope.source == agent }
        for execution in selected { execution.task.cancel() }
        // A handler may retire its own producer. Its enclosing transport still owns the join.
        for (id, execution) in directExecutions
        where execution.scope.source == agent
            && id != OutputDispatchOwnership.current
        {
            _ = await execution.task.result
        }
        outputScopes = outputScopes.filter { $0.source != agent }
        cancelledScopes = cancelledScopes.filter { $0.source != agent }
    }

    private var taskCalls: [String: [String: Task<ToolResponse?, any Error>]] = [:]
    private var taskTerminationFailures: [String: String] = [:]
    private var taskTerminationOrder: [String] = []
    private func retainTaskFailure(_ id: String, message: String) {
        if taskTerminationFailures[id] == nil {
            if taskTerminationOrder.count == 32 { taskTerminationFailures[taskTerminationOrder.removeFirst()] = nil }
            taskTerminationOrder.append(id)
        }
        taskTerminationFailures[id] = message
    }
    public func terminationFailures() -> [String: String] { taskTerminationFailures }
    private func recordTaskTermination(_ event: AgentTaskTermination, outcome: ActionResultDelivery) {
        if case .accepted = outcome { return }
        retainTaskFailure(event.scope.id, message: "Task terminal delivery rejected")
    }

    private func failTaskCompletion(_ scope: AgentTaskScope, owner: ExecutionOwner, reason: String) async {
        do {
            let events = try await manager.failTask(
                scope, executor: owner.agent, incarnation: owner.incarnation, reason: reason)
            for event in events {
                for id in event.executionIDs {
                    await actions.executor.cancel(inputID: id, source: event.scope.executor)
                }
                await cancelTaskCalls(event.scope.id)
                let outcome = await requests.deliverTaskTermination(event)
                recordTaskTermination(event, outcome: outcome)
            }
        } catch CommunicationError.scopeClosed {
            // Concurrent lifecycle retirement already owns joined cleanup.
        } catch CommunicationError.staleIncarnation {
            // The stopped owner's cleanup carries its captured recipient incarnation.
        } catch {
            retainTaskFailure(
                scope.id, message: "Task completion cleanup rejected: " + String(String(describing: error).prefix(512)))
        }
    }
    private func cancelTaskCalls(_ taskID: String) async {
        let calls = taskCalls.removeValue(forKey: taskID) ?? [:]
        for call in calls.values { call.cancel() }
        for call in calls.values { _ = await call.result }
    }
    private func executionOwner(_ envelope: OutputEnvelope) async throws -> ExecutionOwner {
        try await bindLifecycle()
        let identity = try await sourceIdentity(envelope)
        try await manager.validate(envelope.source, incarnation: identity, sessionID: envelope.sessionID)
        let terminalControl: Bool
        if case .control(let value) = envelope.output {
            terminalControl =
                value == "agent.finished" || value == "agent.cancelled" || value.hasPrefix("agent.error:")
                || value == "assistant.finished" || value.hasPrefix("assistant.error:")
        } else {
            terminalControl = false
        }
        if let scope = envelope.taskScope, !terminalControl {
            try await manager.validateTaskInput(scope, agent: envelope.source)
        }
        return ExecutionOwner(agent: envelope.source, incarnation: identity, sessionID: envelope.sessionID)
    }

    public func resourceControl(for source: AgentID, sessionID: String) async throws -> ResourceControl {
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

    /// Trusted host interruption can preempt a round seal waiting for playback completion.
    public func cancelCalls(for producer: any Agent, sessionID: String) async throws {
        guard !closed else { throw CommunicationError.scopeClosed }
        let id = producer.descriptor.id
        let incarnation = try await manager.outputIdentity(for: producer)
        try await manager.validate(id, incarnation: incarnation, sessionID: sessionID)
        let producer = ProducerSession(source: id, session: sessionID)
        cancellingProducers.insert(producer)
        defer { cancellingProducers.remove(producer) }
        cancelledScopes.formUnion(outputScopes.filter { $0.source == id && $0.session == sessionID })
        let direct = directExecutions.values.filter {
            $0.scope.source == id && $0.scope.session == sessionID && !$0.interruption
        }
        for execution in direct { execution.task.cancel() }
        async let scheduled: Void = actions.executor.cancel(agent: id, incarnation: incarnation, sessionID: sessionID)
        for execution in direct { _ = await execution.task.result }
        await scheduled
    }

    public func cancel(sessionID: String) async {
        cancelledScopes.formUnion(outputScopes.filter { $0.session == sessionID })
        let direct = directExecutions.values.filter { $0.scope.session == sessionID }
        for execution in direct { execution.task.cancel() }
        async let cancelled: Void = actions.cancel(sessionID: sessionID)
        await resources?.close(sessionID: sessionID)
        for execution in direct { _ = await execution.task.result }
        await cancelled
    }
    public func shutdown() async {
        closed = true
        let direct = Array(directExecutions.values)
        for execution in direct { execution.task.cancel() }
        for execution in direct { _ = await execution.task.result }
        outputScopes.removeAll()
        cancelledScopes.removeAll()
        roundFailures.removeAll()
        for observer in failureObservers.values { observer.finish() }
        failureObservers.removeAll()
        async let cancelled: Void = actions.shutdown()
        await resources?.shutdown()
        await cancelled
        await requests.shutdown()
        await manager.removeStopObserver(lifecycleObserverID)
    }

    /// Registration metadata for bounded consumers; does not authorize or execute a call.
    public func returnsToolResult(for call: ToolCall) async -> Bool {
        await tools.registry.returnsResult(for: call.toolPath)
    }

    /// Production consumers isolate ordinary output failures; explicit cancellation still joins cleanup.
    @discardableResult
    public func execute(_ envelope: OutputEnvelope) async throws -> OutputExecutionResult {
        let failure: String?
        var code: ActionExecutionFailureCode?
        var tool: ToolResponse?
        let scope = OutputScope(envelope)
        let terminal = Self.isTerminal(envelope.output)
        defer {
            if terminal {
                outputScopes.remove(scope)
                cancelledScopes.remove(scope)
            }
        }
        do {
            if !terminal {
                guard !isCancelled(scope) || Self.isInterruption(envelope) else { throw CancellationError() }
                if envelope.roundID != nil {
                    guard outputScopes.count < 128 || outputScopes.contains(scope) else { throw HarnessError.queueFull }
                    outputScopes.insert(scope)
                }
            }
            tool = try await dispatchOwned(envelope)
            failure = tool?.deliveryFailure
            code = failure == nil ? nil : .deliveryFailed
        } catch {
            try Task.checkCancellation()
            if case .roundFinished = envelope.output, error is CancellationError { throw error }
            if error is CancellationError || FunctionExecutor.failureReport(for: error).isCancellationOnly {
                code = .cancelled
            } else if let producer = error as? any ActionExecutionFailureProviding {
                code = producer.executionFailureCode
            } else if let producer = error as? any ActionReportFailureProviding {
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
        if let roundID = envelope.roundID, let failure, !isCancelled(scope) {
            guard roundFailures.count < 128 || roundFailures[roundID] != nil else { throw HarnessError.queueFull }
            if code == .deliveryFailed {
                roundFailures[roundID] = failure
            } else if let callID = envelope.callID {
                do {
                    let owner = try await executionOwner(envelope)
                    switch envelope.output {
                    case .actionCall(let call):
                        let cancelled = code == .cancelled
                        let report = try ActionReport(entries: [
                            .init(
                                path: call.actionPath.description, status: cancelled ? .cancelled : .failed,
                                code: cancelled ? .cancelled : .handlerFailed,
                                details: ["failureDescription": failure])
                        ])
                        let receipt = ActionResult(
                            executionID: UUID().uuidString, owner: owner, path: call.actionPath,
                            causality: SignalCausality(envelope: envelope),
                            status: cancelled ? .cancelled : .failed, effect: .notStarted,
                            completion: .report(report.agentValue), failure: cancelled ? .cancelled : .handlerFailed,
                            callID: callID,
                            roundID: roundID)
                        guard await requests.deliverActionResult(receipt) == .accepted else {
                            throw CommunicationError.scopeClosed
                        }
                    case .toolCall:
                        _ = try await requests.deliverToolResult(
                            .init(
                                callID: callID, value: failure, isError: true,
                                failureCode: code?.rawValue ?? "handlerFailed", roundID: roundID), owner: owner,
                            envelope: envelope)
                    default: break
                    }
                } catch {
                    try Task.checkCancellation()
                    roundFailures[roundID] = "Execution feedback failed: \(error)"
                }
            } else if case .rejectedCall = envelope.output {
                // Parser-local rejections are already terminal observations in the Agent.
            } else {
                guard roundFailures.count < 128 || roundFailures[roundID] != nil else { throw HarnessError.queueFull }
                roundFailures[roundID] = failure
            }
        }
        let result = OutputExecutionResult(
            source: envelope.source, inputID: envelope.inputID,
            sequence: envelope.sequence, tool: tool, failure: failure, failureCode: code)
        if outputResults.count == 256 {
            outputResults.removeFirst()
            evictedOutputs += 1
        }
        outputResults.append(result)
        if result.isError && !result.isCancellationOnly {
            let reasons = [tool?.isError == true ? tool?.value : nil, failure].compactMap { $0 }
            recordFailure(
                envelope, message: reasons.isEmpty ? "Execution failed" : reasons.joined(separator: "\n"),
                code: code ?? tool?.failureCode)
        }
        return result
    }
    public func executionResults(source: AgentID? = nil, inputID: String? = nil) async -> OutputExecutionSnapshot {
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
        let identity = try await sourceIdentity(envelope)
        try await manager.validate(envelope.source, incarnation: identity, sessionID: envelope.sessionID)
        let descriptor = try await manager.agent(envelope.source).descriptor
        try Task.checkCancellation()
        do {
            var validationDescriptor = descriptor
            switch envelope.output {
            case .actionCall, .toolCall:
                if let roundID = envelope.roundID,
                    let effective = try await manager.agent(envelope.source).effectiveCapabilities(for: roundID)
                {
                    validationDescriptor = AgentDescriptor(
                        id: descriptor.id, name: descriptor.name, version: descriptor.version,
                        inputs: descriptor.inputs, outputs: descriptor.outputs, capabilities: effective)
                }
            default: break
            }
            try OutputValidator.validate(envelope.output, descriptor: validationDescriptor)
        } catch {
            await actions.cancel(envelope)
            throw error
        }
        if case .rejectedCall(let rejection) = envelope.output, rejection.kind == .tool {
            return ToolResponse(
                callID: try rejection.callID ?? UUID().uuidString,
                value: "\(rejection.reason): \(rejection.alias)", isError: true,
                failureCode: rejection.reason == .invalidParameters ? .invalidArguments : .unknownTool)
        }
        switch try ExecutionRouter.route(envelope.output) {
        case .communication(let call):
            try await bindLifecycle()
            let owner = ExecutionOwner(
                agent: envelope.source, incarnation: try await sourceIdentity(envelope), sessionID: envelope.sessionID)
            try await manager.validate(owner.agent, incarnation: owner.incarnation, sessionID: owner.sessionID)
            let report: DeliveryReport
            do {
                report = try await emit(
                    call.message,
                    parent: AgentInput(
                        id: envelope.inputID,
                        sessionID: envelope.sessionID, payload: .observation(call.message),
                        metadata: envelope.inputMetadata, turn: envelope.turn), source: envelope.source,
                    incarnation: owner.incarnation, target: call.target)
            } catch is CancellationError {
                if let task = call.message.content(as: AgentTaskSignal.self) {
                    if task.kind == .result {
                        await failTaskCompletion(
                            task.scope, owner: owner, reason: "Final task report cancelled")
                    }
                }
                throw CancellationError()
            } catch {
                if let task = call.message.content(as: AgentTaskSignal.self) {
                    if task.kind == .result {
                        await failTaskCompletion(task.scope, owner: owner, reason: String(describing: error))
                    }
                }
                report = DeliveryReport(
                    rejected: call.target.map { [$0: String(describing: error)] } ?? [:],
                    failure: String(describing: error))
            }
            if call.target != nil {
                try await requests.deliverCommunicationReceipt(
                    CommunicationReceipt(
                        callID: call.id,
                        report: report, owner: owner, causality: SignalCausality(envelope: envelope)))
            }
        case .action(let token):
            do {
                try Task.checkCancellation()
                let owner = try await executionOwner(envelope)
                if let scope = envelope.taskScope {
                    try await manager.registerExecution(envelope.schedulingID, scope: scope, agent: envelope.source)
                }
                let required = try actions.executor.requiredResources(for: token)
                let lease = await resources?.lease(for: owner, resources: required)
                try await actions.dispatch(
                    token, envelope: envelope, owner: owner,
                    feedback: descriptor.inputs.contains(.actionResult)
                        ? (envelope.roundID != nil ? .terminal : actionFeedback) : .none, lease: lease)
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
            let owner = try await executionOwner(envelope)
            if let scope = envelope.taskScope {
                guard taskCalls.count < 32 || taskCalls[scope.id] != nil,
                    taskCalls[scope.id, default: [:]].count < 16
                else { throw CommunicationError.capacityExceeded }
                let dispatcher = tools
                let execution = Task {
                    try await dispatcher.dispatch(call, envelope: envelope, owner: owner)
                }
                taskCalls[scope.id, default: [:]][call.id] = execution
                defer {
                    taskCalls[scope.id]?[call.id] = nil
                    if taskCalls[scope.id]?.isEmpty == true { taskCalls[scope.id] = nil }
                }
                toolResult = try await withTaskCancellationHandler {
                    try await execution.value
                } onCancel: {
                    execution.cancel()
                }
            } else {
                toolResult = try await tools.dispatch(call, envelope: envelope, owner: owner)
            }
        case .roundFinished:
            guard let roundID = envelope.roundID, case .roundFinished(let sealedID) = envelope.output,
                sealedID == roundID
            else {
                throw CommunicationError.invalidPayload
            }
            let owner = try await executionOwner(envelope)
            var failure = roundFailures.removeValue(forKey: roundID)
            do {
                try await actions.finish(envelope)
                try await actions.executor.finishRoundDelivery(roundID)
            } catch is CancellationError {
                try Task.checkCancellation()
                await actions.cancel(envelope)
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                await actions.cancel(envelope)
                failure = String(describing: error)
            }
            try await requests.deliverRoundResult(
                .init(roundID: roundID, failure: failure), owner: owner, envelope: envelope)
        case .finish:
            do {
                try await actions.finish(envelope)
                if let scope = envelope.taskScope { try await requests.deliverReplyCompletion(scope) }
            } catch {
                await actions.cancel(envelope)
                throw error
            }
        case .cancel:
            if case .control(let value) = envelope.output,
                value.hasPrefix("agent.error:") || value.hasPrefix("assistant.error:")
            {
                recordFailure(envelope, message: value, code: nil)
            }
            if let roundID = envelope.roundID { roundFailures[roundID] = nil }
            await actions.cancel(envelope)
        case .observe: break
        }
        try Task.checkCancellation()
        await sink(envelope)
        return toolResult
    }
}
