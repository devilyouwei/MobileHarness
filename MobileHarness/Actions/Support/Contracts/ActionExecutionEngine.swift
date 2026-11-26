import Foundation

/// Endpoint-identity check and feedback exit that Gateway binds into the engine.
public struct ActionSignalBinding: Sendable {
    public let validate: @Sendable (FunctionInvocation, ExecutionOwner?) async throws -> Void
    public let deliver: @Sendable (ExecutionResult) async -> ActionResultDelivery
    public let deliverStart: @Sendable (ExecutionStart) async -> ActionResultDelivery
    public init(
        validate: @escaping @Sendable (FunctionInvocation, ExecutionOwner?) async throws -> Void,
        deliver: @escaping @Sendable (ExecutionResult) async -> ActionResultDelivery,
        deliverStart: @escaping @Sendable (ExecutionStart) async -> ActionResultDelivery
    ) {
        self.validate = validate
        self.deliver = deliver
        self.deliverStart = deliverStart
    }
}

/// Actions-owned execution engine reached through Gateway: it receives Agent → Action invocation Signals and
/// returns Action → Agent feedback Signals. Scheduling, direct Tool calls and resource arbitration live behind it.
public protocol ActionExecutionEngine: Sendable {
    func enqueue(invocation: ScheduledAction) async throws -> String
    func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope) async throws
    func finish(inputID: String, source: String) async throws
    func cancel(inputID: String, source: String) async
    func cancel(sessionID: String) async
    /// Joins selected work and returns whether its native cleanup was confirmed.
    @discardableResult func cancel(endpoint: String, incarnation: String, sessionID: String?) async -> Bool
    func execute(_ input: FunctionInvocation, owner: ExecutionOwner) async throws -> ActionCompletion
    func requiredResources(for call: FunctionRequest) async throws -> Set<ResourceID>
    func finishRoundDelivery(_ roundID: String) async throws
    func executionSnapshot() async -> ActionExecutionSnapshot
    func lease(for owner: ExecutionOwner, resources: Set<ResourceID>) async -> ResourceLease?
    func acquireLease(resources: Set<ResourceID>, owner: ExecutionOwner, duration: Duration) async throws
        -> ResourceLease
    func renewLease(_ lease: ResourceLease, owner: ExecutionOwner, duration: Duration) async throws -> ResourceLease
    func releaseLease(_ lease: ResourceLease, owner: ExecutionOwner) async throws
    func closeResources(endpoint: String, incarnation: String) async
    func closeResources(sessionID: String) async
    /// Binds once; a second binding fails so one engine never serves two Signal roots.
    func bindSignals(_ binding: ActionSignalBinding) throws
}
