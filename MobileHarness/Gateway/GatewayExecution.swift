import Foundation
import FunctionContracts

/// Agent→Action invocation and Action→Agent feedback edge. Gateway gates new work on its own admission and
/// forwards to the Actions-owned engine; scheduling, direct calls and resources are not implemented here.
public struct GatewayExecution: ActionExecutionEngine {
    private let engine: any ActionExecutionEngine
    private let admission: GatewayAdmission
    init(engine: any ActionExecutionEngine, admission: GatewayAdmission) {
        self.engine = engine
        self.admission = admission
    }
    public func enqueue(invocation: ScheduledAction) async throws -> String {
        try admission.check()
        return try await engine.enqueue(invocation: invocation)
    }
    public func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope) async throws {
        try admission.check()
        try await engine.schedule(directive, envelope: envelope)
    }
    public func finish(inputID: String, source: String) async throws {
        try await engine.finish(inputID: inputID, source: source)
    }
    public func cancel(inputID: String, source: String) async { await engine.cancel(inputID: inputID, source: source) }
    public func cancel(sessionID: String) async { await engine.cancel(sessionID: sessionID) }
    public func cancel(endpoint: String, incarnation: String, sessionID: String?) async {
        await engine.cancel(endpoint: endpoint, incarnation: incarnation, sessionID: sessionID)
    }
    public func execute(_ input: FunctionInvocation, owner: ExecutionOwner) async throws -> ActionCompletion {
        try admission.check()
        return try await engine.execute(input, owner: owner)
    }
    public func requiredResources(for call: FunctionRequest) async throws -> Set<ResourceID> {
        try await engine.requiredResources(for: call)
    }
    public func finishRoundDelivery(_ roundID: String) async throws { try await engine.finishRoundDelivery(roundID) }
    public func executionSnapshot() async -> ActionExecutionSnapshot { await engine.executionSnapshot() }
    public func lease(for owner: ExecutionOwner, resources: Set<ResourceID>) async -> ResourceLease? {
        await engine.lease(for: owner, resources: resources)
    }
    public func acquireLease(resources: Set<ResourceID>, owner: ExecutionOwner, duration: Duration) async throws
        -> ResourceLease
    {
        try admission.check()
        return try await engine.acquireLease(resources: resources, owner: owner, duration: duration)
    }
    public func renewLease(_ lease: ResourceLease, owner: ExecutionOwner, duration: Duration) async throws
        -> ResourceLease
    {
        try admission.check()
        return try await engine.renewLease(lease, owner: owner, duration: duration)
    }
    public func releaseLease(_ lease: ResourceLease, owner: ExecutionOwner) async throws {
        try await engine.releaseLease(lease, owner: owner)
    }
    public func closeResources(endpoint: String, incarnation: String) async {
        await engine.closeResources(endpoint: endpoint, incarnation: incarnation)
    }
    public func closeResources(sessionID: String) async { await engine.closeResources(sessionID: sessionID) }
    public func bindSignals(_ binding: ActionSignalBinding) throws { try engine.bindSignals(binding) }
}

/// Stand-in for isolated observation scopes that have no Actions attached: every invocation is rejected.
public struct DetachedActionExecution: ActionExecutionEngine {
    public init() {}
    public func enqueue(invocation: ScheduledAction) async throws -> String {
        throw ActionExecutionError.missingHandler(invocation.call.actionPath)
    }
    public func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope) async throws {}
    public func finish(inputID: String, source: String) async throws {}
    public func cancel(inputID: String, source: String) async {}
    public func cancel(sessionID: String) async {}
    public func cancel(endpoint: String, incarnation: String, sessionID: String?) async {}
    public func execute(_ input: FunctionInvocation, owner: ExecutionOwner) async throws -> ActionCompletion {
        throw ActionExecutionError.missingHandler(input.call.actionPath)
    }
    public func requiredResources(for call: FunctionRequest) async throws -> Set<ResourceID> {
        throw ActionExecutionError.missingHandler(call.actionPath)
    }
    public func finishRoundDelivery(_ roundID: String) async throws {}
    public func executionSnapshot() async -> ActionExecutionSnapshot {
        ActionExecutionSnapshot(revision: 0, records: [], evictedCount: 0)
    }
    public func lease(for owner: ExecutionOwner, resources: Set<ResourceID>) async -> ResourceLease? { nil }
    public func acquireLease(resources: Set<ResourceID>, owner: ExecutionOwner, duration: Duration) async throws
        -> ResourceLease
    { throw ResourceError.unknownResource }
    public func renewLease(_ lease: ResourceLease, owner: ExecutionOwner, duration: Duration) async throws
        -> ResourceLease
    { throw ResourceError.unknownResource }
    public func releaseLease(_ lease: ResourceLease, owner: ExecutionOwner) async throws {
        throw ResourceError.unknownResource
    }
    public func closeResources(endpoint: String, incarnation: String) async {}
    public func closeResources(sessionID: String) async {}
    public func bindSignals(_ binding: ActionSignalBinding) throws {}
}
