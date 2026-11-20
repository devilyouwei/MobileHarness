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
    }
    public let admission: ActionsAdmission
    public let scheduler: ChannelScheduler
    public let direct: DirectExecutionDispatcher
    public let resources: ResourceCoordinator
    private let binding: Binding

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
            deliverResult: { await binding.deliver($0) }, onExecutionSnapshot: onExecutionSnapshot)
        direct = DirectExecutionDispatcher(
            executor: executor, resources: resources, admission: admission,
            validateScope: { try await binding.validate($0, $1) })
    }

    public func open() { admission.setOpen(true) }
    public func closeAdmission() { admission.setOpen(false) }

    /// Cancels and joins ordinary work and releases leases; the engine can reopen afterwards.
    public func suspend() async throws {
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

    public func enqueue(invocation: ScheduledAction) async throws -> String {
        try await scheduler.enqueue(invocation: invocation)
    }
    public func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope) async throws {
        try await scheduler.schedule(directive, envelope: envelope)
    }
    public func finish(inputID: String, source: String) async throws {
        try await scheduler.finish(inputID: inputID, source: source)
    }
    public func cancel(inputID: String, source: String) async {
        await scheduler.cancel(inputID: inputID, source: source)
    }
    public func cancel(sessionID: String) async { await scheduler.cancel(sessionID: sessionID) }
    public func cancel(endpoint: String, incarnation: String, sessionID: String?) async {
        await scheduler.cancel(endpoint: endpoint, incarnation: incarnation, sessionID: sessionID)
    }
    public func execute(_ input: FunctionInvocation, owner: ExecutionOwner) async throws -> ActionCompletion {
        try await direct.execute(input, owner: owner)
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
