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
        case success
        case failure(any Error)
        func get() throws { if case .failure(let error) = self { throw error } }
    }
    struct Job: Sendable {
        let id = UUID()
        let sequence: UInt64
        let phase: Int
        let path: ActionPath
        let invocation: ActionInvocation
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

    public init(
        registry: ActionRegistry, capacityPerChannel: Int = 32, maximumTrackedInputs: Int = 64,
        maximumChannels: Int = 16
    ) {
        precondition(capacityPerChannel > 0 && maximumTrackedInputs > 0 && maximumChannels > 0)
        self.registry = registry
        self.capacityPerChannel = capacityPerChannel
        self.maximumTrackedInputs = maximumTrackedInputs
        self.maximumChannels = maximumChannels
    }
    private func state(for envelope: OutputEnvelope) throws -> InputState {
        try Task.checkCancellation()
        guard !isShutdown else { throw ActionExecutionError.shutdown }
        let key = InputKey(source: envelope.source, inputID: envelope.inputID)
        if let state = inputs[key] {
            guard state.sessionID == envelope.sessionID else { throw ActionExecutionError.inputSessionMismatch }
            if let error = state.failure { throw error }
            guard !state.finishing && !state.cancelling else { throw ActionExecutionError.inputClosing }
            return state
        }
        guard inputs.count < maximumTrackedInputs else { throw ActionExecutionError.inputCapacityExceeded }
        let state = InputState(sessionID: envelope.sessionID)
        inputs[key] = state
        return state
    }
    /// Returns after admission, never after execution. All dormant jobs count toward capacity.
    public func enqueue(path: ActionPath, invocation: ActionInvocation) throws {
        try Task.checkCancellation()
        guard !isShutdown else { throw ActionExecutionError.shutdown }
        _ = try registry.handler(for: path)
        guard path == invocation.call.actionPath else { throw ActionExecutionError.invalidCall }
        let channel = invocation.call.channel
        guard channelCounts[channel] != nil || channelCounts.count < maximumChannels else {
            throw ActionExecutionError.channelCountExceeded
        }
        guard channelCounts[channel, default: 0] < capacityPerChannel else {
            throw ActionExecutionError.channelCapacityExceeded(channel)
        }
        let state = try state(for: invocation.envelope)
        guard state.acceptedActions < 120 else { throw ActionExecutionError.taskActionLimitExceeded }
        state.acceptedActions += 1
        state.pending += 1
        channelCounts[channel, default: 0] += 1
        sequence += 1
        state.phases[state.writePhase].lanes[channel, default: Channel()].queued.append(
            Job(sequence: sequence, phase: state.writePhase, path: path, invocation: invocation))
        startEligibleChannels()
    }
    public func schedule(_ directive: SchedulingDirective, envelope: OutputEnvelope) throws {
        let key = InputKey(source: envelope.source, inputID: envelope.inputID)
        if directive == .endWait, inputs[key] == nil { throw ActionExecutionError.invalidSchedule }
        let state = try state(for: envelope)
        switch directive {
        case .beginWait:
            guard state.groups.count <= 32, state.stack.count <= 8 else {
                throw ActionExecutionError.waitGroupLimitExceeded
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
            guard state.stack.count > 1 else { throw ActionExecutionError.invalidSchedule }
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
        guard !state.finishing else { throw ActionExecutionError.duplicateFinish }
        state.finishing = true
        if state.stack.count != 1 {
            state.failure = state.failure ?? ActionExecutionError.invalidSchedule
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
    }
    public func shutdown() async {
        isShutdown = true
        let selected = inputs
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
                let outcome: Outcome
                do {
                    try Task.checkCancellation()
                    try await ActionExecutor(registry: registry).execute(job.invocation)
                    try Task.checkCancellation()
                    outcome = .success
                } catch { outcome = .failure(error) }
                self.completed(job, outcome: outcome)
            }
            state.phases[job.phase].lanes[channel]?.running = Running(job: job, task: task)
        }
    }
    private func completed(_ job: Job, outcome: Outcome) {
        guard let state = inputs[job.inputKey],
            state.phases[job.phase].lanes[job.invocation.call.channel]?.running?.job.id == job.id
        else { return }
        state.phases[job.phase].lanes[job.invocation.call.channel]?.running = nil
        busyModules.remove(job.path.module)
        decrementChannel(job.invocation.call.channel, by: 1)
        state.pending -= 1
        if case .failure(let error) = outcome {
            state.failure = state.failure ?? error
            cancelJobs(key: job.inputKey)
        }
        finalizeIfReady(job.inputKey)
        startEligibleChannels()
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
                let count = state.phases[phase].lanes[name]?.queued.count ?? 0
                state.pending -= count
                decrementChannel(name, by: count)
                state.phases[phase].lanes[name]?.queued.removeAll()
                state.phases[phase].lanes[name]?.running?.task.cancel()
            }
        }
    }
    private func finalizeIfReady(_ key: InputKey) {
        guard let state = inputs[key], state.pending == 0,
            state.finishing || state.cancelling || state.failure != nil
        else { return }
        if !state.settled {
            state.settled = true
            state.signal.yield(state.failure.map { .failure($0) } ?? .success)
            state.signal.finish()
        }
        if state.finishing || state.cancelling { inputs.removeValue(forKey: key) }
    }
}
