import Foundation
import FunctionContracts
import Synchronization

/// Closing admission does not assert native completion; cleanup is joined by the engine lifecycle.
public final class ActionsAdmission: Sendable {
    private let available = Mutex(false)
    public init() {}
    public var isOpen: Bool { available.withLock { $0 } }
    func setOpen(_ value: Bool) { available.withLock { $0 = value } }
    public func check() throws { guard isOpen else { throw ActionSchedulingError.unavailable } }
}

/// Actions-owned execution engine: Channel scheduling, direct Tool calls, resource arbitration and result feedback.
/// Gateway reaches it only through ActionExecutionEngine; ActionsContainer owns its lifecycle.
public final class ActionExecutionCoordinator: ActionExecutionEngine {
    private final class Binding: Sendable {
        private let value = Mutex<ActionSignalBinding?>(nil)
        func bind(_ binding: ActionSignalBinding) throws {
            try value.withLock {
                guard $0 == nil else { throw ActionSchedulingError.signalsAlreadyBound }
                $0 = binding
            }
        }
        func validate(_ input: FunctionInvocation, _ owner: ExecutionOwner?) async throws {
            try await value.withLock { $0 }?.validate(input, owner)
        }
        func deliver(_ result: ExecutionResult) async -> ActionResultDelivery {
            guard let binding = value.withLock({ $0 }) else { return .closed }
            return await binding.deliver(result)
        }
        func deliverControl(_ feedback: ActionControlFeedback) async -> ActionResultDelivery {
            guard let binding = value.withLock({ $0 }) else { return .closed }
            return await binding.deliverControl(feedback)
        }
        func deliverStart(_ started: ExecutionStart) async -> ActionResultDelivery {
            guard let binding = value.withLock({ $0 }) else { return .closed }
            return await binding.deliverStart(started)
        }
    }
    public let admission: ActionsAdmission
    public let scheduler: ChannelScheduler
    public let direct: DirectExecutionDispatcher
    public let resources: ResourceCoordinator
    private let binding: Binding

    private struct RoundKey: Hashable {
        let id: String
        let lane: CallLane
        let owner: ExecutionOwner
    }

    private enum RoundState {
        case open(active: Int)
        case sealed(CallRoundSettlement)
        case settled(CallRoundSettlement)
        case cancelled
    }

    private let rounds = Mutex<[RoundKey: RoundState]>([:])

    public func roundBoundary(
        _ boundary: CallRoundBoundary, lane: CallLane, owner: ExecutionOwner
    ) async throws -> CallRoundSettlement? {
        try admission.check()
        guard UUID(uuidString: boundary.roundID) != nil else { throw ActionExecutionError.invalidInvocation }
        let key = RoundKey(id: boundary.roundID, lane: lane, owner: owner)
        return try rounds.withLock { states -> CallRoundSettlement? in
            switch (boundary.scope, states[key]) {
            case (.start, .open), (.start, .sealed), (.start, .settled):
                return nil
            case (.start, nil):
                guard !states.keys.contains(where: { $0.id == key.id && $0.owner != owner }) else {
                    throw ActionExecutionError.invalidInvocation
                }
                if states.count >= 256 {
                    states = states.filter { _, state in
                        switch state {
                        case .settled, .cancelled: false
                        case .open, .sealed: true
                        }
                    }
                }
                guard states.count < 256 else { throw ActionSchedulingError.inputCapacityExceeded }
                states[key] = .open(active: 0)
                return nil
            case (.end, .open(active: 0)):
                let task = Task {
                    defer {
                        rounds.withLock {
                            if case .sealed(let settlement) = $0[key] { $0[key] = .settled(settlement) }
                        }
                    }
                    if lane == .action {
                        do {
                            try await scheduler.finish(scope: .round(boundary.roundID), source: owner.endpoint)
                        } catch {
                            await scheduler.cancel(scope: .round(boundary.roundID), source: owner.endpoint)
                            throw error
                        }
                        try await scheduler.finishRoundDelivery(boundary.roundID)
                    }
                }
                let settlement = CallRoundSettlement(task: task)
                states[key] = .sealed(settlement)
                return settlement
            case (.end, .sealed(let settlement)), (.end, .settled(let settlement)):
                return settlement
            default:
                throw ActionSchedulingError.invalidSchedule
            }
        }
    }

    private func beginCall(roundID: String?, lane: CallLane, owner: ExecutionOwner?) throws -> RoundKey? {
        guard let roundID else { return nil }
        guard let owner else { throw ActionExecutionError.invalidInvocation }
        let key = RoundKey(id: roundID, lane: lane, owner: owner)
        try rounds.withLock {
            guard case .open(let active) = $0[key] else { throw ActionSchedulingError.invalidSchedule }
            $0[key] = .open(active: active + 1)
        }
        return key
    }

    private func endCall(_ key: RoundKey?) {
        guard let key else { return }
        rounds.withLock {
            if case .open(let active) = $0[key] { $0[key] = .open(active: active - 1) }
        }
    }

    private func cancelRounds(where predicate: (RoundKey) -> Bool) {
        rounds.withLock { states in
            for key in states.keys.filter(predicate) {
                if case .open = states[key] { states[key] = .cancelled }
            }
        }
    }

    public init(
        executor: ActionsExecutionPort, resources definitions: [ResourceDefinition],
        resultDeliveryTimeout: Duration = .seconds(60),
        onExecutionSnapshot: (@Sendable (ActionExecutionSnapshot) -> Void)? = nil
    ) throws {
        let admission = ActionsAdmission()
        let binding = Binding()
        let resources = try ResourceCoordinator(definitions: definitions, admission: admission)
        self.admission = admission
        self.binding = binding
        self.resources = resources
        scheduler = ChannelScheduler(
            executor: executor, resources: resources, resultDeliveryTimeout: resultDeliveryTimeout,
            admission: admission, validateScope: { try await binding.validate($0, $1) },
            deliverResult: { await binding.deliver($0) }, onExecutionSnapshot: onExecutionSnapshot,
            deliverStart: { await binding.deliverStart($0) }, deliverControl: { await binding.deliverControl($0) })
        direct = DirectExecutionDispatcher(
            executor: executor, resources: resources, admission: admission,
            validateScope: { try await binding.validate($0, $1) })
    }

    public func open() { admission.setOpen(true) }
    public func closeAdmission() { admission.setOpen(false) }

    /// Cancels and joins ordinary work and releases leases; the engine can reopen afterwards.
    public func suspend() async throws {
        cancelRounds { _ in true }
        async let scheduled: Void = scheduler.suspend()
        async let directWork: Void = direct.suspend()
        var failure: (any Error)?
        do { try await resources.closeLifecycle(permanently: false) } catch { failure = error }
        _ = await (scheduled, directWork)
        if let failure { throw failure }
    }

    public func shutdown() async throws {
        admission.setOpen(false)
        var errors: [any Error] = []
        do { try await suspend() } catch { errors.append(error) }
        await scheduler.shutdown()
        await direct.shutdown()
        do { try await resources.closeLifecycle(permanently: true) } catch { errors.append(error) }
        if !errors.isEmpty { throw NativeCleanupFailure(errors: errors) }
    }

    public func bindSignals(_ signals: ActionSignalBinding) throws { try binding.bind(signals) }

    public func control(_ control: ActionControl, owner: ExecutionOwner) async throws -> ActionControlReceipt? {
        try admission.check()
        return await scheduler.control(control, owner: owner)
    }
    public func enqueue(invocation: ScheduledAction) async throws -> String {
        let key = try beginCall(roundID: invocation.envelope.roundID, lane: .action, owner: invocation.owner)
        defer { endCall(key) }
        return try await scheduler.enqueue(invocation: invocation)
    }
    public func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope) async throws {
        try await scheduler.schedule(directive, envelope: envelope)
    }
    public func finish(scope: ActionSchedulingScope, source: String) async throws {
        try await scheduler.finish(scope: scope, source: source)
    }
    public func cancel(scope: ActionSchedulingScope, source: String) async {
        if case .round(let id) = scope { cancelRounds { $0.id == id && $0.owner.endpoint == source } }
        await scheduler.cancel(scope: scope, source: source)
    }
    public func cancel(sessionID: String) async {
        cancelRounds { $0.owner.sessionID == sessionID }
        await scheduler.cancel(sessionID: sessionID)
    }
    @discardableResult public func cancel(endpoint: String, incarnation: String, sessionID: String?) async -> Bool {
        cancelRounds {
            $0.owner.endpoint == endpoint && $0.owner.incarnation == incarnation
                && (sessionID == nil || $0.owner.sessionID == sessionID)
        }
        return await scheduler.cancel(endpoint: endpoint, incarnation: incarnation, sessionID: sessionID)
    }
    public func execute(_ input: FunctionInvocation, owner: ExecutionOwner) async throws -> ActionCompletion {
        let key = try beginCall(roundID: input.roundID, lane: .tool, owner: owner)
        defer { endCall(key) }
        return try await direct.execute(input, owner: owner)
    }
    public func requiredResources(for call: FunctionRequest) async throws -> Set<ResourceID> {
        try await scheduler.requiredResources(for: call)
    }
    public func finishRoundDelivery(_ roundID: String) async throws {
        try await scheduler.finishRoundDelivery(roundID)
    }
    public func executionSnapshot() async -> ActionExecutionSnapshot { await scheduler.executionSnapshot() }

    public func lease(for owner: ExecutionOwner, resources requested: Set<ResourceID>) async -> ResourceLease? {
        await resources.lease(for: owner, resources: requested)
    }
    public func acquireLease(resources requested: Set<ResourceID>, owner: ExecutionOwner, duration: Duration)
        async throws -> ResourceLease
    {
        try await resources.acquire(resources: requested, owner: owner, duration: duration, cancelling: scheduler)
    }
    public func renewLease(_ lease: ResourceLease, owner: ExecutionOwner, duration: Duration) async throws
        -> ResourceLease
    {
        try await resources.renew(lease, owner: owner, duration: duration)
    }
    public func releaseLease(_ lease: ResourceLease, owner: ExecutionOwner) async throws {
        try await resources.release(lease, owner: owner)
    }
    public func closeResources(endpoint: String, incarnation: String) async {
        await resources.close(endpoint: endpoint, incarnation: incarnation)
    }
    public func closeResources(sessionID: String) async { await resources.close(sessionID: sessionID) }
}
