import ActionRuntime
import AgentCore
import Foundation

/// Task-local structured execution groups with process-wide module exclusion.
public actor ChannelScheduler {
    struct InputKey: Hashable {
        let source: AgentID
        let inputID: UUID
    }
    private enum Outcome: Sendable {
        case success(ActionCompletion)
        case failure(any Error)
        func get() throws { if case .failure(let error) = self { throw error } }
    }
    struct Job: Sendable {
        var id: UUID { invocation.executionID }
        let sequence: UInt64
        let phase: Int
        let kind: ActionDefinition.Kind
        let resources: Set<ResourceID>
        var path: ActionPath { invocation.call.actionPath }
        let invocation: ScheduledAction
        var inputKey: InputKey { InputKey(source: invocation.envelope.source, inputID: invocation.envelope.inputID) }
    }
    struct Running {
        let job: Job
        let task: Task<Void, Never>
    }
    private enum Entry {
        case phase(Int)
        case group(Int)
    }
    private struct Group {
        var entries: [Entry]
        var cursor = 0
        var closed = false
    }
    private struct Phase {
        var lanes: [String: Channel] = [:]
        var closed = false
        var empty: Bool { lanes.values.allSatisfy { $0.count == 0 } }
    }
    /// Reference state is owned exclusively by this actor; it never crosses an executor boundary.
    private final class InputState {
        let sessionID: UUID
        let completion: Task<Outcome, Never>
        let signal: AsyncStream<Outcome>.Continuation
        var phases = [Phase()]
        var groups = [Group(entries: [.phase(0)])]
        var stack = [0]
        var writePhase = 0
        var acceptedActions = 0
        var pending = 0
        var failure: (any Error)?
        var finishing = false
        var cancelling = false
        // Failed tasks remain fenced until their producer finishes or explicit cancellation joins them.
        var settled = false

        init(sessionID: UUID) {
            self.sessionID = sessionID
            let pair = AsyncStream<Outcome>.makeStream(bufferingPolicy: .bufferingOldest(1))
            signal = pair.continuation
            completion = Task {
                for await outcome in pair.stream { return outcome }
                return .failure(CancellationError())
            }
        }
        func activePhase(in groupID: Int = 0) -> Int? {
            while groups[groupID].cursor < groups[groupID].entries.count {
                switch groups[groupID].entries[groups[groupID].cursor] {
                case .phase(let phase):
                    if !phases[phase].closed || !phases[phase].empty { return phase }
                case .group(let child):
                    if let phase = activePhase(in: child) { return phase }
                    if !groups[child].closed { return nil }
                }
                groups[groupID].cursor += 1
            }
            return nil
        }
    }
    private let registry: ActionRegistry
    private let capacityPerChannel: Int
    private let maximumChannels: Int
    private let maximumTrackedInputs: Int
    private var inputs: [InputKey: InputState] = [:]
    private var channelCounts: [String: Int] = [:]
    private var isShutdown = false
    private var sequence: UInt64 = 0
    private var busyModules: Set<String> = []
    private var executionLedger = ActionExecutionLedger()
    private var executionObservers: [UUID: AsyncStream<ActionExecutionSnapshot>.Continuation] = [:]
    public enum ObservationError: Error { case capacityExceeded }

    /// Full snapshots coalesce safely: a slow observer never blocks execution or needs delta replay.
    public func observeExecutions() throws -> AsyncStream<ActionExecutionSnapshot> {
        guard executionObservers.count < 8 else { throw ObservationError.capacityExceeded }
        let id = UUID()
        let pair = AsyncStream<ActionExecutionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.yield(executionLedger.snapshot())
        if isShutdown {
            pair.continuation.finish()
        } else {
            executionObservers[id] = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in
                Task { await self?.removeExecutionObserver(id) }
            }
        }
        return pair.stream
    }
    public func executionSnapshot() -> ActionExecutionSnapshot { executionLedger.snapshot() }
    private func removeExecutionObserver(_ id: UUID) { executionObservers.removeValue(forKey: id) }
    private func publishExecutions() {
        guard !executionObservers.isEmpty else { return }
        let snapshot = executionLedger.snapshot()
        for observer in executionObservers.values { observer.yield(snapshot) }
    }
    private func executionTransition(
        _ id: UUID, to phase: ActionExecutionRecord.Phase,
        completion: ActionCompletion? = nil, failure: ActionExecutionRecord.Failure? = nil,
        failureDescription: String? = nil
    ) {
        if executionLedger.transition(
            id, to: phase, completion: completion, failure: failure, failureDescription: failureDescription)
        {
            publishExecutions()
        }
    }

    private var diagnostics: ActionDiagnostics
    private let resources: ResourceCoordinator?
    private var resultLedger: ActionResultLedger
    private let deliverResult: @Sendable (ActionResult) async -> ActionResultDelivery
    private var deliveryWorker: Task<Void, Never>?
    private var deliveryAttempt: Task<Void, Never>?
    private var deliveryAttemptID: UUID?

    public func finishResultDelivery() async { await deliveryWorker?.value }

    public func resultSnapshot() -> [(executionID: UUID, result: ActionResult?, delivery: String)] {
        resultLedger.snapshot().map { ($0.executionID, $0.result, $0.state.rawValue) }
    }

    public nonisolated var resourceCoordinator: ResourceCoordinator? { resources }

    public nonisolated func requiredResources(for call: ActionCall) throws -> Set<ResourceID> {
        try registry.definition(for: call.actionPath).requiredResources(for: call)
    }

    public func diagnosticSnapshot() -> ActionDiagnostics.Snapshot { diagnostics.snapshot() }

    public init(
        registry: ActionRegistry, capacityPerChannel: Int = 32, maximumTrackedInputs: Int = 64,
        maximumChannels: Int = 16, diagnosticCapacity: Int = 256,
        resources: ResourceCoordinator? = nil, resultCapacity: Int = 512,
        deliverResult: @escaping @Sendable (ActionResult) async -> ActionResultDelivery = { _ in .closed }
    ) {
        precondition(capacityPerChannel > 0 && maximumTrackedInputs > 0 && maximumChannels > 0)
        self.registry = registry
        self.resources = resources
        self.resultLedger = ActionResultLedger(capacity: resultCapacity)
        self.deliverResult = deliverResult
        self.diagnostics = ActionDiagnostics(capacity: diagnosticCapacity)
        self.capacityPerChannel = capacityPerChannel
        self.maximumTrackedInputs = maximumTrackedInputs
        self.maximumChannels = maximumChannels
    }
    private func state(for envelope: OutputEnvelope) throws -> InputState {
        try Task.checkCancellation()
        guard !isShutdown else { throw ActionSchedulingError.shutdown }
        let key = InputKey(source: envelope.source, inputID: envelope.inputID)
        if let state = inputs[key] {
            guard state.sessionID == envelope.sessionID else { throw ActionSchedulingError.inputSessionMismatch }
            if let error = state.failure { throw error }
            guard !state.finishing && !state.cancelling else { throw ActionSchedulingError.inputClosing }
            return state
        }
        guard inputs.count < maximumTrackedInputs else { throw ActionSchedulingError.inputCapacityExceeded }
        let state = InputState(sessionID: envelope.sessionID)
        inputs[key] = state
        return state
    }
    /// Returns after admission, never after execution. All dormant jobs count toward capacity.
    @discardableResult
    public func enqueue(invocation submitted: ScheduledAction) async throws -> UUID {
        let invocation = try ScheduledAction(
            envelope: submitted.envelope, owner: submitted.owner, feedback: submitted.feedback, lease: submitted.lease)
        try Task.checkCancellation()
        guard !isShutdown else { throw ActionSchedulingError.shutdown }
        let definition = try registry.definition(for: invocation.call.actionPath)
        let required = try definition.requiredResources(for: invocation.call)
        if !required.isEmpty {
            guard let resources else { throw ResourceError.unknownResource }
            try await resources.validate(
                resources: required, owner: invocation.owner, lease: invocation.lease)
        }
        // Recheck state after the resource actor hop, before reserving capacity.
        try Task.checkCancellation()
        guard !isShutdown else { throw ActionSchedulingError.shutdown }
        try resultLedger.checkCapacity(invocation)
        let channel = invocation.call.channel
        guard channelCounts[channel] != nil || channelCounts.count < maximumChannels else {
            throw ActionSchedulingError.channelCountExceeded
        }
        guard channelCounts[channel, default: 0] < capacityPerChannel else {
            throw ActionSchedulingError.channelCapacityExceeded(channel)
        }
        let state = try state(for: invocation.envelope)
        guard state.acceptedActions < 120 else { throw ActionSchedulingError.taskActionLimitExceeded }
        resultLedger.reserve(invocation)
        state.acceptedActions += 1
        state.pending += 1
        channelCounts[channel, default: 0] += 1
        sequence += 1
        state.phases[state.writePhase].lanes[channel, default: Channel()].queued.append(
            Job(
                sequence: sequence, phase: state.writePhase, kind: definition.kind, resources: required,
                invocation: invocation))
        executionLedger.admit(invocation, definition: definition)
        publishExecutions()
        diagnostics.record(invocation, kind: definition.kind, phase: .admitted, effect: .notStarted)
        startEligibleChannels()
        return invocation.executionID
    }
    public func schedule(_ directive: SchedulingDirective, envelope: OutputEnvelope) throws {
        let key = InputKey(source: envelope.source, inputID: envelope.inputID)
        if directive == .endWait, inputs[key] == nil { throw ActionSchedulingError.invalidSchedule }
        let state = try state(for: envelope)
        switch directive {
        case .beginWait:
            guard state.groups.count <= 32, state.stack.count <= 8 else {
                throw ActionSchedulingError.waitGroupLimitExceeded
            }
            let parent = state.stack.last!
            state.phases[state.writePhase].closed = true
            let child = state.groups.count
            let phase = state.phases.count
            state.groups[parent].entries.append(.group(child))
            state.groups.append(Group(entries: [.phase(phase)]))
            state.phases.append(Phase())
            state.stack.append(child)
            state.writePhase = phase
        case .endWait:
            guard state.stack.count > 1 else { throw ActionSchedulingError.invalidSchedule }
            state.phases[state.writePhase].closed = true
            let child = state.stack.removeLast()
            state.groups[child].closed = true
            let parent = state.stack.last!
            let phase = state.phases.count
            state.phases.append(Phase())
            state.groups[parent].entries.append(.phase(phase))
            state.writePhase = phase
        }
        startEligibleChannels()
    }
    /// Seals the root group and joins all accepted work. Only one finish waiter is admitted.
    public func finish(inputID: UUID, source: AgentID = .assistant) async throws {
        let key = InputKey(source: source, inputID: inputID)
        guard let state = inputs[key] else {
            try Task.checkCancellation()
            return
        }
        guard !state.finishing else { throw ActionSchedulingError.duplicateFinish }
        state.finishing = true
        if state.stack.count != 1 {
            state.failure = state.failure ?? ActionSchedulingError.invalidSchedule
            cancelJobs(key: key)
        } else {
            state.phases[state.writePhase].closed = true
            state.groups[0].closed = true
        }
        startEligibleChannels()
        finalizeIfReady(key)
        let outcome = await withTaskCancellationHandler {
            await state.completion.value
        } onCancel: {
            Task { await self.cancel(inputID: inputID, source: source) }
        }
        try outcome.get()
        try Task.checkCancellation()
    }
    public func cancel(inputID: UUID, source: AgentID = .assistant) async {
        let key = InputKey(source: source, inputID: inputID)
        guard let completion = inputs[key]?.completion else { return }
        beginCancellation(key)
        _ = await completion.value
    }
    public func cancel(sessionID: UUID) async {
        let selected = inputs.filter { $0.value.sessionID == sessionID }
        for key in selected.keys { beginCancellation(key) }
        for state in selected.values { _ = await state.completion.value }
        resultLedger.close(sessionID: sessionID)
    }
    public func shutdown() async {
        isShutdown = true
        let selected = inputs
        for key in selected.keys { beginCancellation(key) }
        for state in selected.values { _ = await state.completion.value }
        resultLedger.close()
        deliveryWorker?.cancel()
        deliveryAttempt?.cancel()
        for observer in executionObservers.values { observer.finish() }
        executionObservers.removeAll()
    }

    public func cancel(agent: AgentID, incarnation: UUID) async {
        let selected = inputs.filter { key, state in
            key.source == agent
                && state.phases.contains { phase in
                    phase.lanes.values.contains { lane in
                        lane.queued.contains { $0.invocation.owner?.incarnation == incarnation }
                            || lane.running?.job.invocation.owner?.incarnation == incarnation
                    }
                }
        }
        for key in selected.keys { beginCancellation(key) }
        for state in selected.values { _ = await state.completion.value }
    }

    public func cancel(resources revoked: Set<ResourceID>) async {
        let selected = inputs.filter { _, state in
            state.phases.contains { phase in
                phase.lanes.values.contains { lane in
                    lane.queued.contains { !$0.resources.isDisjoint(with: revoked) }
                        || lane.running.map { !$0.job.resources.isDisjoint(with: revoked) } == true
                }
            }
        }
        for key in selected.keys { beginCancellation(key) }
        for state in selected.values { _ = await state.completion.value }
    }

    private func startEligibleChannels() {
        var candidates: [Job] = []
        for state in inputs.values where state.failure == nil && !state.cancelling {
            guard let phase = state.activePhase() else { continue }
            for lane in state.phases[phase].lanes.values where lane.running == nil {
                if let first = lane.queued.first { candidates.append(first) }
            }
        }
        for job in candidates.sorted(by: { $0.sequence < $1.sequence }) {
            guard !busyModules.contains(job.path.module), let state = inputs[job.inputKey] else { continue }
            let channel = job.invocation.call.channel
            state.phases[job.phase].lanes[channel]?.queued.removeFirst()
            busyModules.insert(job.path.module)
            let task = Task {
                var outcome: Outcome
                var started = false
                do {
                    try Task.checkCancellation()
                    started = true
                    self.executionTransition(job.id, to: .running)
                    self.diagnostics.record(job.invocation, kind: job.kind, phase: .started, effect: .unknown)
                    let completion: ActionCompletion
                    if !job.resources.isEmpty, let resources {
                        let executor = ActionExecutor(registry: registry)
                        completion = try await resources.run(
                            resources: job.resources, owner: job.invocation.owner, lease: job.invocation.lease
                        ) { try await executor.execute(job.invocation.execution) }
                    } else {
                        completion = try await ActionExecutor(registry: registry).execute(job.invocation.execution)
                    }
                    try Task.checkCancellation()
                    outcome = .success(completion)
                } catch {
                    if let reported = error as? any ActionReportProviding {
                        outcome = .success(.report(reported.actionReport))
                    } else {
                        outcome = .failure(error)
                    }
                }
                if let report = await job.invocation.results.snapshot() {
                    switch outcome {
                    case .failure(let error):
                        outcome = .success(.report(report.recordingFailure(error)))
                    case .success(.report(let terminal)):
                        outcome = .success(
                            .report(
                                terminal.executionFailure.map { report.withExecutionFailure($0) } ?? report))
                    case .success:
                        outcome = .success(.report(report))
                    }
                }
                self.completed(job, outcome: outcome, started: started)
            }
            state.phases[job.phase].lanes[channel]?.running = Running(job: job, task: task)
        }
    }
    private func completed(_ job: Job, outcome: Outcome, started: Bool) {
        guard let state = inputs[job.inputKey],
            state.phases[job.phase].lanes[job.invocation.call.channel]?.running?.job.id == job.id
        else { return }
        state.phases[job.phase].lanes[job.invocation.call.channel]?.running = nil
        busyModules.remove(job.path.module)
        decrementChannel(job.invocation.call.channel, by: 1)
        state.pending -= 1
        switch outcome {
        case .success(let completion):
            let report: ActionReport?
            if case .report(let value) = completion { report = value } else { report = nil }
            let status = report?.status ?? .succeeded
            let phase: ActionExecutionRecord.Phase =
                status == .cancelled ? .cancelled : (status == .succeeded ? .succeeded : .failed)
            var issues =
                report?.entries.filter { $0.status == .failed }.map {
                    "\($0.path): \($0.code?.rawValue ?? "handlerFailed")"
                } ?? []
            if let failure = report?.executionFailure { issues.append("execution: \(failure.rawValue)") }
            let description = issues.joined(separator: "; ")
            executionTransition(
                job.id, to: phase, completion: completion,
                failure: status == .succeeded ? nil : .operationFailed,
                failureDescription: description)
            resultLedger.complete(
                job.invocation, status: status.agentValue,
                effect: status == .succeeded ? .contractCompleted : .unknown, completion: completion,
                failure: status == .succeeded ? nil : (status == .cancelled ? .cancelled : .handlerFailed))
            diagnostics.record(
                job.invocation, kind: job.kind,
                phase: status == .cancelled ? .cancelled : (status == .succeeded ? .succeeded : .failed),
                effect: status == .succeeded ? .contractCompleted : .unknown)
        case .failure(let error):
            let report = ActionReport.failure(ActionReport.code(for: error))
            executionTransition(
                job.id, to: error is CancellationError ? .cancelled : .failed, completion: .report(report),
                failure: error is CancellationError
                    ? nil
                    : ((error as? any ActionExecutionFailureProviding)?.actionExecutionFailure.observationFailure
                        ?? (error is ResourceError ? .resourceUnavailable : .operationFailed)),
                failureDescription: error is CancellationError ? nil : error.localizedDescription)
            resultLedger.complete(
                job.invocation, status: error is CancellationError ? .cancelled : .failed,
                effect: started ? .unknown : .notStarted, completion: .report(report),
                failure: error is CancellationError
                    ? .cancelled : (error is ResourceError ? .resourceUnavailable : .handlerFailed))
            diagnostics.record(
                job.invocation, kind: job.kind, phase: error is CancellationError ? .cancelled : .failed,
                effect: started ? .unknown : .notStarted)
        }
        finalizeIfReady(job.inputKey)
        startEligibleChannels()
        startResultDelivery()
    }
    private func beginCancellation(_ key: InputKey) {
        guard let state = inputs[key] else { return }
        state.cancelling = true
        state.failure = state.failure ?? CancellationError()
        cancelJobs(key: key)
        finalizeIfReady(key)
        startEligibleChannels()
    }
    private func decrementChannel(_ name: String, by count: Int) {
        guard count > 0 else { return }
        let remaining = channelCounts[name, default: 0] - count
        if remaining == 0 { channelCounts.removeValue(forKey: name) } else { channelCounts[name] = remaining }
    }
    private func cancelJobs(key: InputKey) {
        guard let state = inputs[key] else { return }
        for phase in state.phases.indices {
            for name in Array(state.phases[phase].lanes.keys) {
                let queued = state.phases[phase].lanes[name]?.queued ?? []
                for job in queued {
                    executionTransition(job.id, to: .cancelled)
                    resultLedger.complete(job.invocation, status: .cancelled, effect: .notStarted, failure: .cancelled)
                    diagnostics.record(job.invocation, kind: job.kind, phase: .cancelled, effect: .notStarted)
                }
                let count = queued.count
                state.pending -= count
                decrementChannel(name, by: count)
                state.phases[phase].lanes[name]?.queued.removeAll()
                if let running = state.phases[phase].lanes[name]?.running {
                    executionTransition(running.job.id, to: .cancelling)
                    running.task.cancel()
                }
            }
        }
        startResultDelivery()
    }
    private func finalizeIfReady(_ key: InputKey) {
        guard let state = inputs[key], state.pending == 0,
            state.finishing || state.cancelling || state.failure != nil
        else { return }
        if !state.settled {
            state.settled = true
            state.signal.yield(state.failure.map { .failure($0) } ?? .success(.completed))
            state.signal.finish()
        }
        if state.finishing || state.cancelling { inputs.removeValue(forKey: key) }
    }
}

extension ChannelScheduler {
    private func startResultDelivery() {
        guard !isShutdown, deliveryWorker == nil, resultLedger.hasPending else { return }
        deliveryWorker = Task { await self.deliverResults() }
    }

    private func deliverResults() async {
        defer { deliveryWorker = nil }
        while !Task.isCancelled, !isShutdown, resultLedger.hasPending {
            let next = resultLedger.ready()
            if let result = next, deliveryAttempt == nil {
                let pair = AsyncStream<ActionResultDelivery>.makeStream(bufferingPolicy: .bufferingOldest(1))
                let attemptID = UUID()
                deliveryAttemptID = attemptID
                deliveryAttempt = Task {
                    let outcome = await deliverResult(result)
                    pair.continuation.yield(outcome)
                    pair.continuation.finish()
                    self.finishDeliveryAttempt(attemptID)
                }
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    pair.continuation.yield(.retry)
                    pair.continuation.finish()
                }
                var iterator = pair.stream.makeAsyncIterator()
                let outcome = await iterator.next() ?? .closed
                timeout.cancel()
                resultLedger.delivered(result.executionID, outcome: outcome)
                if deliveryAttemptID == attemptID { deliveryAttempt?.cancel() }
            } else {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func finishDeliveryAttempt(_ id: UUID) {
        guard deliveryAttemptID == id else { return }
        deliveryAttempt = nil
        deliveryAttemptID = nil
        startResultDelivery()
    }
}
