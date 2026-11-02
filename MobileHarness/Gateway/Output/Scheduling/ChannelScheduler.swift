import Foundation
import FunctionContracts

/// Task-local structured execution groups with Channel FIFO and independent resource arbitration.
public actor ChannelScheduler {
    struct InputKey: Hashable {
        let source: String
        let inputID: String
    }
    enum Outcome: Sendable {
        case success(ActionCompletion)
        case failure(any Error)
        func get() throws { if case .failure(let error) = self { throw error } }
    }
    struct Job: Sendable {
        var id: String { invocation.executionID }
        let sequence: UInt64
        let phase: Int
        let kind: ActionFunction.Kind
        let resources: Set<ResourceID>
        var path: ActionIdentifier { invocation.call.actionPath }
        let invocation: ScheduledAction
        var inputKey: InputKey {
            InputKey(source: invocation.envelope.source, inputID: invocation.envelope.schedulingID)
        }
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
        let sessionID: String
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
        var retainCancelledBoundary = false
        var producerIncarnation: String?
        // Failed tasks remain fenced until their producer finishes or explicit cancellation joins them.
        var settled = false

        init(sessionID: String) {
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
    private let admission: GatewayAdmission?
    private let validateScope: @Sendable (FunctionInvocation, ExecutionOwner?) async throws -> Void
    private var preparingChannels: [String: Int] = [:]
    private var preparationCount = 0
    private var admissionWork: [UUID: (ScheduledAction, Task<String, any Error>)] = [:]
    private let executor: ActionsExecutionPort
    private let capacityPerChannel: Int
    private let maximumChannels: Int
    private let maximumTrackedInputs: Int
    private var inputs: [InputKey: InputState] = [:]
    private var channelCounts: [String: Int] = [:]
    private var isShutdown = false
    private var sequence: UInt64 = 0
    private var discards: [String: Task<Void, Never>] = [:]
    private var executionLedger = ActionExecutionLedger()
    private var executionObservers: [String: AsyncStream<ActionExecutionSnapshot>.Continuation] = [:]
    public enum ObservationError: Error { case capacityExceeded }

    /// Full snapshots coalesce safely: a slow observer never blocks execution or needs delta replay.
    public func observeExecutions() throws -> AsyncStream<ActionExecutionSnapshot> {
        guard executionObservers.count < 8 else { throw ObservationError.capacityExceeded }
        let id = UUID().uuidString
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
    private func removeExecutionObserver(_ id: String) { executionObservers.removeValue(forKey: id) }
    private func publishExecutions() {
        guard !executionObservers.isEmpty else { return }
        let snapshot = executionLedger.snapshot()
        for observer in executionObservers.values { observer.yield(snapshot) }
    }
    private func executionTransition(
        _ id: String, to phase: ActionExecutionRecord.Phase,
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
    private let deliverResult: @Sendable (ExecutionResult) async -> ActionResultDelivery
    private var deliveryWorker: Task<Void, Never>?
    private var deliveryAttempt: Task<Void, Never>?
    private var deliveryAttemptID: String?

    public func finishRoundDelivery(_ roundID: String) async throws {
        while true {
            try Task.checkCancellation()
            let records = resultLedger.snapshot().filter { $0.result?.roundID == roundID }
            if let failed = records.first(where: { $0.state == .closed }) {
                throw ActionSchedulingError.resultDeliveryFailed(
                    executionID: failed.executionID,
                    path: failed.result?.path.description ?? "unknown", state: failed.state.rawValue)
            }
            if !records.contains(where: { $0.state == .pending || $0.state == .reserved }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    public func finishResultDelivery() async { await deliveryWorker?.value }

    public func resultSnapshot() -> [(executionID: String, result: ExecutionResult?, delivery: String)] {
        resultLedger.snapshot().map { ($0.executionID, $0.result, $0.state.rawValue) }
    }

    public nonisolated var resourceCoordinator: ResourceCoordinator? { resources }

    public nonisolated func requiredResources(for call: FunctionRequest) async throws -> Set<ResourceID> {
        let input = FunctionInvocation(
            call: call, context: .init(source: "", sessionID: "", inputID: ""), executionID: UUID().uuidString,
            results: ActionReportStore())
        let ticket = try await executor.prepare(input, .action)
        await executor.discard(ticket)
        return ticket.resources
    }

    public func stateSnapshot() async throws -> GatewayStateSnapshot {
        try Task.checkCancellation()
        return GatewayStateSnapshot(
            path: "gateway.scheduler",
            runtime: [
                "inputs": .count(inputs.count), "channels": .count(channelCounts.count),
                "preparing": .count(preparationCount), "trackedResults": .count(resultLedger.snapshot().count),
                "closed": .flag(isShutdown),
            ])
    }
    public func diagnosticSnapshot() -> ActionDiagnostics.Snapshot { diagnostics.snapshot() }

    public init(
        executor: ActionsExecutionPort, capacityPerChannel: Int = 32, maximumTrackedInputs: Int = 64,
        maximumChannels: Int = 16, diagnosticCapacity: Int = 256,
        resources: ResourceCoordinator? = nil, resultCapacity: Int = 512,
        admission: GatewayAdmission? = nil,
        validateScope: @escaping @Sendable (FunctionInvocation, ExecutionOwner?) async throws -> Void = { _, _ in },
        deliverResult: @escaping @Sendable (ExecutionResult) async -> ActionResultDelivery = { _ in .closed }
    ) {
        precondition(capacityPerChannel > 0 && maximumTrackedInputs > 0 && maximumChannels > 0)
        self.admission = admission
        self.validateScope = validateScope
        self.executor = executor
        self.resources = resources
        self.resultLedger = ActionResultLedger(capacity: resultCapacity)
        self.deliverResult = deliverResult
        self.diagnostics = ActionDiagnostics(capacity: diagnosticCapacity)
        self.capacityPerChannel = capacityPerChannel
        self.maximumTrackedInputs = maximumTrackedInputs
        self.maximumChannels = maximumChannels
    }
    private func state(for envelope: ExecutionEnvelope) throws -> InputState {
        try Task.checkCancellation()
        guard !isShutdown else { throw ActionSchedulingError.shutdown }
        try admission?.check()
        let key = InputKey(source: envelope.source, inputID: envelope.schedulingID)
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
    public func enqueue(invocation submitted: ScheduledAction) async throws -> String {
        try admission?.check()
        guard admissionWork.count < 128 else { throw ActionSchedulingError.inputCapacityExceeded }
        let id = UUID()
        let task = Task { try await self.admit(submitted) }
        admissionWork[id] = (submitted, task)
        defer { admissionWork[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    private func admit(_ submitted: ScheduledAction) async throws -> String {
        try Task.checkCancellation()
        guard !isShutdown else { throw ActionSchedulingError.shutdown }
        try admission?.check()
        guard preparationCount < 128 else { throw ActionSchedulingError.inputCapacityExceeded }
        let channel = submitted.channel
        guard channelCounts[channel, default: 0] + preparingChannels[channel, default: 0] < capacityPerChannel else {
            throw ActionSchedulingError.channelCapacityExceeded(channel)
        }
        guard
            Set(channelCounts.keys).union(preparingChannels.keys).contains(channel)
                || Set(channelCounts.keys).union(preparingChannels.keys).count < maximumChannels
        else {
            throw ActionSchedulingError.channelCountExceeded
        }
        preparationCount += 1
        preparingChannels[channel, default: 0] += 1
        defer {
            preparationCount -= 1
            if preparingChannels[channel] == 1 {
                preparingChannels[channel] = nil
            } else {
                preparingChannels[channel, default: 0] -= 1
            }
        }
        guard submitted.envelope.context.source == submitted.envelope.source,
            submitted.envelope.context.sessionID == submitted.envelope.sessionID,
            submitted.envelope.context.inputID == submitted.envelope.inputID
        else {
            throw ActionExecutionError.invalidInvocation
        }
        try await validateScope(submitted.execution, submitted.owner)
        let ticket = try await executor.prepare(submitted.execution, .action)
        do {
            let invocation = try submitted.preparing(ticket)
            let definition = ticket.descriptor
            let required = ticket.resources
            if !required.isEmpty {
                guard let resources else { throw ResourceError.unknownResource }
                try await resources.validateAdmission(
                    resources: required, owner: invocation.owner, lease: invocation.lease)
            }
            // Recheck state after the resource actor hop, before reserving capacity.
            try Task.checkCancellation()
            guard !isShutdown else { throw ActionSchedulingError.shutdown }
            try admission?.check()
            try await validateScope(invocation.execution, invocation.owner)
            try resultLedger.checkCapacity(invocation)
            let channel = invocation.channel
            guard channelCounts[channel] != nil || channelCounts.count < maximumChannels else {
                throw ActionSchedulingError.channelCountExceeded
            }
            guard channelCounts[channel, default: 0] < capacityPerChannel else {
                throw ActionSchedulingError.channelCapacityExceeded(channel)
            }
            let state = try state(for: invocation.envelope)
            guard state.acceptedActions < 120 else { throw ActionSchedulingError.taskActionLimitExceeded }
            if let incarnation = invocation.owner?.incarnation {
                guard state.producerIncarnation == nil || state.producerIncarnation == incarnation else {
                    throw ActionExecutionError.invalidInvocation
                }
                state.producerIncarnation = incarnation
            }
            resultLedger.reserve(invocation)
            state.acceptedActions += 1
            state.pending += 1
            channelCounts[channel, default: 0] += 1
            sequence += 1
            state.phases[state.writePhase].lanes[channel, default: Channel()].queued.append(
                Job(
                    sequence: sequence, phase: state.writePhase,
                    kind: definition.kind, resources: required,
                    invocation: invocation))
            executionLedger.admit(invocation, definition: definition)
            publishExecutions()
            diagnostics.record(invocation, kind: definition.kind, phase: .admitted, effect: .notStarted)
            startEligibleChannels()
            return invocation.executionID
        } catch {
            await executor.discard(ticket)
            throw error
        }
    }

    public func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope) throws {
        try admission?.check()
        let key = InputKey(source: envelope.source, inputID: envelope.schedulingID)
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
    public func finish(inputID: String, source: String) async throws {
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
    public func cancel(inputID: String, source: String) async {
        await joinAdmissions { $0.envelope.source == source && $0.envelope.schedulingID == inputID }
        let key = InputKey(source: source, inputID: inputID)
        guard let completion = inputs[key]?.completion else { return }
        beginCancellation(key)
        _ = await completion.value
    }
    public func cancel(sessionID: String) async {
        await joinAdmissions { $0.envelope.sessionID == sessionID }
        let selected = inputs.filter { $0.value.sessionID == sessionID }
        for key in selected.keys { beginCancellation(key) }
        for state in selected.values { _ = await state.completion.value }
        resultLedger.close(sessionID: sessionID)
    }
    func suspend() async {
        await joinAdmissions { _ in true }
        let selected = inputs
        for key in selected.keys { beginCancellation(key) }
        for state in selected.values { _ = await state.completion.value }
        // Pending retry evidence remains bounded and may be delivered after resume.
        await deliveryAttempt?.value
    }

    public func shutdown() async {
        isShutdown = true
        await joinAdmissions { _ in true }
        let selected = inputs
        for key in selected.keys { beginCancellation(key) }
        for state in selected.values { _ = await state.completion.value }
        for discard in Array(discards.values) { await discard.value }
        resultLedger.close()
        deliveryWorker?.cancel()
        deliveryAttempt?.cancel()
        await deliveryAttempt?.value
        await deliveryWorker?.value
        for observer in executionObservers.values { observer.finish() }
        executionObservers.removeAll()
    }

    private func joinAdmissions(where matches: (ScheduledAction) -> Bool) async {
        let tasks = admissionWork.values.filter { matches($0.0) }.map { $0.1 }
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.result }
    }
    public func cancel(endpoint: String, incarnation: String, sessionID: String? = nil) async {
        await joinAdmissions {
            $0.owner?.endpoint == endpoint && $0.owner?.incarnation == incarnation
                && (sessionID == nil || $0.envelope.sessionID == sessionID)
        }
        let selected = inputs.filter { key, state in
            key.source == endpoint && (sessionID == nil || state.sessionID == sessionID)
                && state.producerIncarnation == incarnation
        }
        for key in selected.keys { beginCancellation(key, retainBoundary: sessionID != nil) }
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
        guard admission?.isOpen != false else { return }
        var candidates: [Job] = []
        for state in inputs.values where state.failure == nil && !state.cancelling {
            guard let phase = state.activePhase() else { continue }
            for lane in state.phases[phase].lanes.values where lane.running == nil {
                if let first = lane.queued.first { candidates.append(first) }
            }
        }
        for job in candidates.sorted(by: { $0.sequence < $1.sequence }) {
            guard let state = inputs[job.inputKey] else {
                continue
            }
            let channel = job.invocation.channel
            state.phases[job.phase].lanes[channel]?.queued.removeFirst()
            let task = Task {
                var outcome: Outcome
                var started = false
                do {
                    try Task.checkCancellation()
                    started = true
                    self.executionTransition(job.id, to: .running)
                    self.diagnostics.record(job.invocation, kind: job.kind, phase: .started, effect: .unknown)
                    let completion: ActionCompletion
                    guard let ticket = job.invocation.prepared else { throw ActionExecutionError.invalidInvocation }
                    let executor = self.executor
                    if !job.resources.isEmpty, let resources {
                        completion = try await resources.run(
                            resources: job.resources, owner: job.invocation.owner, lease: job.invocation.lease
                        ) { try await executor.execute(ticket) }
                    } else {
                        completion = try await executor.execute(ticket)
                    }
                    if !completion.hasExecutionFailure { try Task.checkCancellation() }
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
                        // The executor already merged stored children with the terminal error/deadline.
                        // Re-reading the older store must not erase terminal entries or its captured cause.
                        outcome = .success(.report(terminal))
                    case .success(.value) where !report.hasFailures && !report.isCancelled:
                        break  // Successful child evidence must not replace the final business receipt.
                    case .success:
                        outcome = .success(.report(report))
                    }
                }
                if let ticket = job.invocation.prepared { await self.executor.discard(ticket) }
                self.completed(job, outcome: outcome, started: started)
            }
            state.phases[job.phase].lanes[channel]?.running = Running(job: job, task: task)
        }
    }
    private func completed(_ job: Job, outcome: Outcome, started: Bool) {
        guard let state = inputs[job.inputKey],
            state.phases[job.phase].lanes[job.invocation.channel]?.running?.job.id == job.id
        else { return }
        state.phases[job.phase].lanes[job.invocation.channel]?.running = nil
        decrementChannel(job.invocation.channel, by: 1)
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
            let description = report?.failureDescription ?? issues.joined(separator: "; ")
            executionTransition(
                job.id, to: phase, completion: completion,
                failure: status == .succeeded || status == .cancelled ? nil : .operationFailed,
                failureDescription: description)
            resultLedger.complete(
                job.invocation, status: status.executionResultStatus,
                effect: status == .succeeded ? .contractCompleted : .unknown, completion: completion,
                failure: status == .succeeded ? nil : (status == .cancelled ? .cancelled : .handlerFailed))
            diagnostics.record(
                job.invocation, kind: job.kind,
                phase: status == .cancelled ? .cancelled : (status == .succeeded ? .succeeded : .failed),
                effect: status == .succeeded ? .contractCompleted : .unknown)
        case .failure(let error):
            let report = ActionReport.failureReport(for: error)
            let cancelled = report.isCancellationOnly
            executionTransition(
                job.id, to: cancelled ? .cancelled : .failed, completion: .report(report),
                failure: cancelled
                    ? nil
                    : ((error as? any ActionReportFailureProviding).map {
                        ActionExecutionRecord.Failure(rawValue: $0.actionExecutionFailure.rawValue)
                    }
                        ?? (error is ResourceError ? .resourceUnavailable : .operationFailed)),
                failureDescription: cancelled ? nil : ActionReport.description(for: error))
            resultLedger.complete(
                job.invocation, status: cancelled ? .cancelled : .failed,
                effect: started ? .unknown : .notStarted, completion: .report(report),
                failure: cancelled
                    ? .cancelled : (error is ResourceError ? .resourceUnavailable : .handlerFailed))
            diagnostics.record(
                job.invocation, kind: job.kind, phase: cancelled ? .cancelled : .failed,
                effect: started ? .unknown : .notStarted)
        }
        finalizeIfReady(job.inputKey)
        startEligibleChannels()
        startResultDelivery()
    }
    private func beginCancellation(_ key: InputKey, retainBoundary: Bool = false) {
        guard let state = inputs[key] else { return }
        state.retainCancelledBoundary = retainBoundary
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
                    if let ticket = job.invocation.prepared {
                        let executor = self.executor
                        discards[job.id] = Task {
                            await executor.discard(ticket)
                            self.discardFinished(job.id)
                        }
                    }
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
    private func discardFinished(_ id: String) { discards[id] = nil }

    private func finalizeIfReady(_ key: InputKey) {
        guard let state = inputs[key], state.pending == 0,
            state.finishing || state.cancelling || state.failure != nil
        else { return }
        if !state.settled {
            state.settled = true
            state.signal.yield(state.failure.map { .failure($0) } ?? .success(.completed))
            state.signal.finish()
        }
        if state.finishing || (state.cancelling && !state.retainCancelledBoundary) { inputs.removeValue(forKey: key) }
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
                let attemptID = UUID().uuidString
                deliveryAttemptID = attemptID
                deliveryAttempt = Task {
                    let outcome = await deliverResult(result)
                    pair.continuation.yield(outcome)
                    pair.continuation.finish()
                    self.finishDeliveryAttempt(attemptID)
                }
                var iterator = pair.stream.makeAsyncIterator()
                let outcome = await iterator.next() ?? .closed
                resultLedger.delivered(result.executionID, outcome: outcome)
                if deliveryAttemptID == attemptID { deliveryAttempt?.cancel() }
            } else {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func finishDeliveryAttempt(_ id: String) {
        guard deliveryAttemptID == id else { return }
        deliveryAttempt = nil
        deliveryAttemptID = nil
        startResultDelivery()
    }
}
