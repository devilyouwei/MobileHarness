import Foundation

public enum CallLane: String, Codable, Sendable, Hashable {
    case action, tool
}

public struct CallRoundBoundary: Sendable {
    public let roundID: String
    public let scope: CallScope

    public init(roundID: String, scope: CallScope) {
        self.roundID = roundID
        self.scope = scope
    }
}

public struct CallRoundSettlement: Sendable {
    private let task: Task<Void, any Error>

    public init(task: Task<Void, any Error>) {
        self.task = task
    }

    public func wait() async throws { try await task.value }
}

/// Endpoint-identity check and feedback exit that Gateway binds into the engine.
public struct ActionSignalBinding: Sendable {
    public let validate: @Sendable (FunctionInvocation, ExecutionOwner?) async throws -> Void
    public let deliver: @Sendable (ExecutionResult) async -> ActionResultDelivery
    public let deliverControl: @Sendable (ActionControlFeedback) async -> ActionResultDelivery
    public let deliverStart: @Sendable (ExecutionStart) async -> ActionResultDelivery
    public init(
        validate: @escaping @Sendable (FunctionInvocation, ExecutionOwner?) async throws -> Void,
        deliver: @escaping @Sendable (ExecutionResult) async -> ActionResultDelivery,
        deliverStart: @escaping @Sendable (ExecutionStart) async -> ActionResultDelivery,
        deliverControl: @escaping @Sendable (ActionControlFeedback) async -> ActionResultDelivery = { _ in .closed }
    ) {
        self.validate = validate
        self.deliver = deliver
        self.deliverStart = deliverStart
        self.deliverControl = deliverControl
    }
}

/// Actions-owned execution engine reached through Gateway: it receives Agent → Action invocation Signals and
/// returns Action → Agent feedback Signals. Scheduling, direct Tool calls and resource arbitration live behind it.
public protocol ActionExecutionEngine: Sendable {
    func roundBoundary(
        _ boundary: CallRoundBoundary, lane: CallLane, owner: ExecutionOwner
    ) async throws -> CallRoundSettlement?
    func control(_ control: ActionControl, owner: ExecutionOwner) async throws -> ActionControlReceipt?
    func enqueue(invocation: ScheduledAction) async throws -> String
    func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope) async throws
    func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope, owner: ExecutionOwner)
        async throws
    func finish(scope: ActionSchedulingScope, source: String) async throws
    func cancel(scope: ActionSchedulingScope, source: String) async
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

extension ActionExecutionEngine {
    public func roundBoundary(
        _ boundary: CallRoundBoundary, lane: CallLane, owner: ExecutionOwner
    ) async throws -> CallRoundSettlement? {
        guard boundary.scope == .end else { return nil }
        return CallRoundSettlement(
            task: Task {
                if lane == .action {
                    try await self.finish(scope: .round(boundary.roundID), source: owner.endpoint)
                    try await self.finishRoundDelivery(boundary.roundID)
                }
            })
    }

    public func schedule(
        _ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope, owner: ExecutionOwner
    ) async throws {
        guard owner.endpoint == envelope.source, owner.sessionID == envelope.sessionID else {
            throw ActionExecutionError.invalidInvocation
        }
        let scope: CallScope?
        let parameters: [String: String]
        switch directive {
        case .beginWait:
            scope = .start
            parameters = [:]
        case .endWait:
            scope = .end
            parameters = [:]
        case .pause(let milliseconds):
            scope = nil
            parameters = ["time": String(Double(milliseconds) / 1000)]
        }
        _ = try await enqueue(
            invocation: ScheduledAction(
                envelope: envelope, call: .init(actionPath: ScheduledAction.waitPath, parameters: parameters),
                channel: "Wait", owner: owner, scope: scope))
    }

    public func control(_ control: ActionControl, owner: ExecutionOwner) async throws -> ActionControlReceipt? {
        .init(control, status: .unsupported)
    }
}
