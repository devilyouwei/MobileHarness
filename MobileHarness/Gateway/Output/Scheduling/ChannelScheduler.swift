import ActionRuntime
import AgentCore
import Foundation

/// Each resolved channel owns a FIFO lane. A handler must await its actual work (including playback).
public actor ChannelScheduler {
    struct InputKey: Hashable {
        let source: AgentID
        let inputID: UUID
    }

    private enum Outcome: Sendable {
        case success
        case failure(any Error)

        func get() throws {
            if case .failure(let error) = self { throw error }
        }
    }

    struct Job: Sendable {
        let id = UUID()
        let sequence: UInt64
        let path: ActionPath
        let invocation: ActionInvocation
        var inputKey: InputKey {
            InputKey(source: invocation.envelope.source, inputID: invocation.envelope.inputID)
        }
    }

    struct Running {
        let job: Job
        let task: Task<Void, Never>
    }

    private struct InputState {
        let sessionID: UUID
        let completion: Task<Outcome, Never>
        let signal: AsyncStream<Outcome>.Continuation
        var pending = 0
        var failure: (any Error)?
        var finishing = false
        var cancelling = false

        init(sessionID: UUID) {
            self.sessionID = sessionID
            let pair = AsyncStream<Outcome>.makeStream(bufferingPolicy: .bufferingOldest(1))
            signal = pair.continuation
            completion = Task {
                for await outcome in pair.stream { return outcome }
                return .failure(CancellationError())
            }
        }
    }

    private let registry: ActionRegistry
    private let capacityPerChannel: Int
    private let maximumChannels: Int
    private let maximumTrackedInputs: Int
    private var lanes: [String: Channel] = [:]
    private var inputs: [InputKey: InputState] = [:]
    private var isShutdown = false
    private var sequence: UInt64 = 0
    private var busyModules: Set<String> = []

    public init(
        registry: ActionRegistry, capacityPerChannel: Int = 32, maximumTrackedInputs: Int = 64,
        maximumChannels: Int = 16
    ) {
        precondition(capacityPerChannel > 0 && maximumTrackedInputs > 0 && maximumChannels > 0)
        self.maximumChannels = maximumChannels
        self.registry = registry
        self.capacityPerChannel = capacityPerChannel
        self.maximumTrackedInputs = maximumTrackedInputs
    }

    /// Returns after admission; overflow rejects the action without evicting another action.
    public func enqueue(path: ActionPath, invocation: ActionInvocation) throws {
        try Task.checkCancellation()
        guard !isShutdown else { throw ActionExecutionError.shutdown }
        _ = try registry.handler(for: path)
        guard path == invocation.call.actionPath else { throw ActionExecutionError.invalidCall }
        guard lanes[invocation.call.channel] != nil || lanes.count < maximumChannels else {
            throw ActionExecutionError.channelCountExceeded
        }
        let key = InputKey(source: invocation.envelope.source, inputID: invocation.envelope.inputID)
        if let state = inputs[key] {
            guard state.sessionID == invocation.envelope.sessionID else {
                throw ActionExecutionError.inputSessionMismatch
            }
            guard !state.finishing && !state.cancelling else { throw ActionExecutionError.inputClosing }
            if let error = state.failure { throw error }
        } else {
            guard inputs.count < maximumTrackedInputs else { throw ActionExecutionError.inputCapacityExceeded }
        }
        guard (lanes[invocation.call.channel]?.count ?? 0) < capacityPerChannel else {
            throw ActionExecutionError.channelCapacityExceeded(invocation.call.channel)
        }
        if inputs[key] == nil {
            inputs[key] = InputState(sessionID: invocation.envelope.sessionID)
        }
        inputs[key]?.pending += 1
        sequence += 1
        lanes[invocation.call.channel, default: Channel()].queued.append(
            Job(sequence: sequence, path: path, invocation: invocation))
        startNext(channel: invocation.call.channel)
    }

    /// Seal one agent's input after its last token, then wait for its accepted actions.
    /// At most one finish waiter may be active for each (agent, input) pair.
    public func finish(inputID: UUID, source: AgentID = .assistant) async throws {
        let key = InputKey(source: source, inputID: inputID)
        guard var state = inputs[key] else {
            try Task.checkCancellation()
            return
        }
        guard !state.finishing else { throw ActionExecutionError.duplicateFinish }
        state.finishing = true
        inputs[key] = state
        finalizeIfReady(key)
        let outcome = await withTaskCancellationHandler {
            await state.completion.value
        } onCancel: {
            Task { await self.cancel(inputID: inputID, source: source) }
        }
        try outcome.get()
        try Task.checkCancellation()
    }

    /// Stop the producer before calling cancel, so it cannot admit later tokens for this ID.
    /// Cancellation is cooperative; this barrier waits for running handlers to return.
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

    private func startNext(channel: String) {
        guard var lane = lanes[channel], lane.running == nil else { return }
        guard !lane.queued.isEmpty else {
            lanes.removeValue(forKey: channel)
            return
        }
        guard !busyModules.contains(lane.queued[0].path.module) else { return }
        let job = lane.queued.removeFirst()
        busyModules.insert(job.path.module)
        let task = Task {
            let outcome: Outcome
            do {
                try Task.checkCancellation()
                try await ActionExecutor(registry: registry).execute(job.invocation)
                try Task.checkCancellation()
                outcome = .success
            } catch {
                outcome = .failure(error)
            }
            self.completed(job, outcome: outcome)
        }
        lane.running = Running(job: job, task: task)
        lanes[channel] = lane
    }

    private func completed(_ job: Job, outcome: Outcome) {
        guard lanes[job.invocation.call.channel]?.running?.job.id == job.id else { return }
        lanes[job.invocation.call.channel]?.running = nil
        busyModules.remove(job.path.module)
        inputs[job.inputKey]?.pending -= 1
        if case .failure(let error) = outcome {
            if inputs[job.inputKey]?.failure == nil { inputs[job.inputKey]?.failure = error }
            cancelJobs(key: job.inputKey)
        }
        finalizeIfReady(job.inputKey)
        startEligibleChannels()
    }

    /// Preserve admission order between ready heads competing for the same physical module.
    private func startEligibleChannels() {
        let ready = lanes.keys.sorted {
            (lanes[$0]?.queued.first?.sequence ?? UInt64.max) < (lanes[$1]?.queued.first?.sequence ?? UInt64.max)
        }
        for channel in ready { startNext(channel: channel) }
    }

    private func beginCancellation(_ key: InputKey) {
        guard inputs[key] != nil else { return }
        inputs[key]?.cancelling = true
        if inputs[key]?.failure == nil { inputs[key]?.failure = CancellationError() }
        cancelJobs(key: key)
        startEligibleChannels()
        finalizeIfReady(key)
    }

    private func cancelJobs(key: InputKey) {
        for channel in Array(lanes.keys) {
            guard var lane = lanes[channel] else { continue }
            let before = lane.queued.count
            lane.queued.removeAll { $0.inputKey == key }
            inputs[key]?.pending -= before - lane.queued.count
            if lane.running?.job.inputKey == key { lane.running?.task.cancel() }
            if lane.count == 0 {
                lanes.removeValue(forKey: channel)
            } else {
                lanes[channel] = lane
            }
        }
    }

    private func finalizeIfReady(_ key: InputKey) {
        guard let state = inputs[key], state.pending == 0, state.finishing || state.cancelling else {
            return
        }
        inputs.removeValue(forKey: key)
        state.signal.yield(state.failure.map { .failure($0) } ?? .success)
        state.signal.finish()
    }
}
