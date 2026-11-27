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

/// Endpoint-identity check and feedback exit supplied by application composition.
public struct ActionSignalBinding: Sendable {
    public let validate: @Sendable (FunctionInvocation, ExecutionOwner?) async throws -> Void
    public let deliver: @Sendable (CallResultSignal) async -> ActionResultDelivery
    public let deliverControl: @Sendable (ActionControlFeedback) async -> ActionResultDelivery
    public let deliverStart: @Sendable (ExecutionStart) async -> ActionResultDelivery
    public init(
        validate: @escaping @Sendable (FunctionInvocation, ExecutionOwner?) async throws -> Void,
        deliver: @escaping @Sendable (CallResultSignal) async -> ActionResultDelivery,
        deliverStart: @escaping @Sendable (ExecutionStart) async -> ActionResultDelivery,
        deliverControl: @escaping @Sendable (ActionControlFeedback) async -> ActionResultDelivery = { _ in .closed }
    ) {
        self.validate = validate
        self.deliver = deliver
        self.deliverStart = deliverStart
        self.deliverControl = deliverControl
    }
}

public enum ActionCallSignal: Sendable {
    public static let channel = "action.call"
    public static let contract = "action.call.v1"
    case call(ScheduledAction)
    case round(CallRoundBoundary)
}

public enum ToolCallSignal: Sendable {
    public static let channel = "tool.call"
    public static let contract = "tool.call.v1"
    case call(FunctionInvocation)
    case round(CallRoundBoundary)
}

public enum CallReply: Sendable {
    case acknowledged(String)
    case round(CallRoundSettlement?)
}

/// The Actions receiver consumes an identity derived from the registered transport endpoint.
public struct ActionExecutionEndpoint: Sendable {
    private let engine: any ActionExecutionEngine
    private let deliverResult: @Sendable (CallResultSignal) async -> ActionResultDelivery

    public init(
        engine: any ActionExecutionEngine,
        deliverResult: @escaping @Sendable (CallResultSignal) async -> ActionResultDelivery
    ) {
        self.engine = engine
        self.deliverResult = deliverResult
    }

    public func receive(_ signal: ActionCallSignal, owner: ExecutionOwner) async throws -> CallReply {
        switch signal {
        case .call(let action):
            guard action.owner == owner else { throw ActionExecutionError.invalidInvocation }
            return .acknowledged(try await engine.enqueue(invocation: action))
        case .round(let boundary):
            return .round(try await engine.roundBoundary(boundary, lane: .action, owner: owner))
        }
    }

    public func receive(_ signal: ToolCallSignal, owner: ExecutionOwner) async throws -> CallReply {
        switch signal {
        case .call(let invocation):
            guard invocation.context.source == owner.endpoint, invocation.context.sessionID == owner.sessionID else {
                throw ActionExecutionError.invalidInvocation
            }
            let outcome: Result<ActionCompletion, any Error>
            do {
                outcome = .success(try await engine.execute(invocation, owner: owner))
            } catch {
                // A cancelled request can still report an actual execution or cleanup failure.
                if Task.isCancelled { throw error }
                outcome = .failure(error)
            }
            let result = ToolExecutionResult(
                executionID: invocation.executionID, owner: owner, inputID: invocation.context.inputID,
                roundID: invocation.roundID, outcome: outcome)
            do {
                while true {
                    try Task.checkCancellation()
                    switch await deliverResult(.tool(result)) {
                    case .accepted: return .acknowledged(result.executionID)
                    case .retry: try await Task.sleep(for: .milliseconds(20))
                    case .closed:
                        try Task.checkCancellation()
                        throw ActionSchedulingError.resultDeliveryFailed(
                            executionID: result.executionID, path: invocation.call.actionPath.description,
                            state: "closed")
                    }
                }
            } catch {
                _ = try outcome.get()
                throw error
            }
        case .round(let boundary):
            return .round(try await engine.roundBoundary(boundary, lane: .tool, owner: owner))
        }
    }

    public func receive(_ control: ActionControl, owner: ExecutionOwner) async throws -> ActionControlReceipt? {
        guard UUID(uuidString: control.executionID) != nil, control.controlSequence > 0 else {
            throw ActionExecutionError.invalidInvocation
        }
        return try await engine.control(control, owner: owner)
    }
}

/// App-injected management of actions, resources, and joined cleanup.
public protocol ActionExecutionManagement: Sendable {
    func finish(scope: ActionSchedulingScope, source: String) async throws
    func cancel(scope: ActionSchedulingScope, source: String) async
    func cancel(sessionID: String) async
    /// Joins selected work and returns whether its native cleanup was confirmed.
    @discardableResult func cancel(endpoint: String, incarnation: String, sessionID: String?) async -> Bool
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
}

/// Actions-owned execution and the corresponding caller port.
public protocol ActionExecutionEngine: ActionExecutionManagement {
    func roundBoundary(
        _ boundary: CallRoundBoundary, lane: CallLane, owner: ExecutionOwner
    ) async throws -> CallRoundSettlement?
    func control(_ control: ActionControl, owner: ExecutionOwner) async throws -> ActionControlReceipt?
    func enqueue(invocation: ScheduledAction) async throws -> String
    func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope) async throws
    func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope, owner: ExecutionOwner)
        async throws
    func execute(_ input: FunctionInvocation, owner: ExecutionOwner) async throws -> ActionCompletion
}

public protocol ActionExecutionHost: ActionExecutionEngine {
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
