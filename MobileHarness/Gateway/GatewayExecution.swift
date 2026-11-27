import Foundation
import FunctionContracts
import Synchronization

/// Agent→Action invocation and Action→Agent feedback edge. Gateway gates new work on its own admission and
/// forwards to the Actions-owned engine; scheduling, direct calls and resources are not implemented here.
public final class GatewayExecution: ActionExecutionEngine {
    private enum Contract {
        static let actionCall = "action.call.v1"
        static let actionControl = "action.control.v1"
        static let toolCall = "action.tool.v1"
    }

    private static let actionControlChannel = "action.control"
    public static let actionCallChannel = "action.call"

    private static let toolCallChannel = "action.tool"
    private enum ActionCallDelivery: Sendable {
        case invoke(ScheduledAction)
        case round(RoundDelivery)
    }
    private final class ActionControlDelivery: Sendable {
        let control: ActionControl
        let response = Mutex<ActionControlReceipt?>(nil)

        init(control: ActionControl) { self.control = control }
    }

    private enum ToolDelivery: Sendable {
        case invoke(ToolCallDelivery)
        case round(RoundDelivery)
    }

    private final class RoundDelivery: Sendable {
        let boundary: CallRoundBoundary
        let settlement = Mutex<CallRoundSettlement?>(nil)

        init(_ boundary: CallRoundBoundary) { self.boundary = boundary }

        func receive(_ engine: any ActionExecutionEngine, lane: CallLane, owner: ExecutionOwner) async throws {
            let result = try await engine.roundBoundary(boundary, lane: lane, owner: owner)
            settlement.withLock { $0 = result }
        }
    }

    private final class ToolCallDelivery: Sendable {
        let invocation: FunctionInvocation
        let result = SignalReplyBox<ActionCompletion>()

        init(invocation: FunctionInvocation) { self.invocation = invocation }
    }

    private let engine: any ActionExecutionEngine
    private let admission: GatewayAdmission
    private let signals: SignalTransport
    private let endpointIncarnation = UUID().uuidString
    private let activeControls = Mutex(0)

    init(engine: any ActionExecutionEngine, admission: GatewayAdmission, signals: SignalTransport) {
        self.engine = engine
        self.admission = admission
        self.signals = signals
    }

    private func actionEndpoint() async throws -> SignalEndpoint {
        try await signals.register(address: "gateway.actions", incarnation: endpointIncarnation) { [engine] signal in
            guard let source = signal.source else { throw SignalTransportError.staleEndpoint }
            let owner = ExecutionOwner(
                endpoint: source.address, incarnation: source.incarnation, sessionID: signal.envelope.sessionID)
            switch signal.envelope.contract {
            case Contract.actionCall:
                guard let delivery = signal.payload as? ActionCallDelivery else {
                    throw SignalTransportError.invalidEnvelope
                }
                switch delivery {
                case .invoke(let invocation):
                    guard invocation.owner == owner else { throw SignalTransportError.invalidEnvelope }
                    _ = try await engine.enqueue(invocation: invocation)
                case .round(let delivery):
                    try await delivery.receive(engine, lane: .action, owner: owner)
                }
            case Contract.actionControl:
                guard let delivery = signal.payload as? ActionControlDelivery else {
                    throw SignalTransportError.invalidEnvelope
                }
                let owner = ExecutionOwner(
                    endpoint: source.address, incarnation: source.incarnation, sessionID: signal.envelope.sessionID)
                let receipt = try await engine.control(delivery.control, owner: owner)
                delivery.response.withLock { $0 = receipt }
            case Contract.toolCall:
                guard let delivery = signal.payload as? ToolDelivery else {
                    throw SignalTransportError.invalidEnvelope
                }
                switch delivery {
                case .invoke(let call):
                    let result = try await engine.execute(call.invocation, owner: owner)
                    call.result.store(result)
                case .round(let boundary):
                    try await boundary.receive(engine, lane: .tool, owner: owner)
                }
            default:
                throw SignalTransportError.unsupportedProtocol
            }
        }
    }

    public func enqueue(invocation: ScheduledAction) async throws -> String {
        try admission.check()
        guard let owner = invocation.owner else { throw ActionExecutionError.invalidInvocation }
        let source = try await signals.executionEndpoint(address: owner.endpoint, incarnation: owner.incarnation)
        let target = try await actionEndpoint()
        let bytes = invocation.call.parameters.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        try await signals.send(
            source: source, target: target,
            envelope: .init(
                id: invocation.executionID, sessionID: owner.sessionID, contract: Contract.actionCall,
                channel: Self.actionCallChannel,
                payloadBytes: bytes + invocation.call.actionPath.description.utf8.count),
            payload: ActionCallDelivery.invoke(invocation))
        return invocation.executionID
    }

    public func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope) async throws {
        try admission.check()
        let source = try await signals.executionEndpoint(address: envelope.source)
        let owner = ExecutionOwner(
            endpoint: source.address, incarnation: source.incarnation, sessionID: envelope.sessionID)
        try await schedule(directive, envelope: envelope, owner: owner)
    }

    public func roundBoundary(
        _ boundary: CallRoundBoundary, lane: CallLane, owner: ExecutionOwner
    ) async throws -> CallRoundSettlement? {
        try admission.check()
        let source = try await signals.executionEndpoint(address: owner.endpoint, incarnation: owner.incarnation)
        let target = try await actionEndpoint()
        let delivery = RoundDelivery(boundary)
        let contract: String
        let channel: String
        let payload: any Sendable
        switch lane {
        case .action:
            contract = Contract.actionCall
            channel = Self.actionCallChannel
            payload = ActionCallDelivery.round(delivery)
        case .tool:
            contract = Contract.toolCall
            channel = Self.toolCallChannel
            payload = ToolDelivery.round(delivery)
        }
        try await signals.send(
            source: source, target: target,
            envelope: .init(
                id: UUID().uuidString, sessionID: owner.sessionID, contract: contract, channel: channel,
                payloadBytes: boundary.roundID.utf8.count + boundary.scope.rawValue.utf8.count),
            payload: payload)
        return delivery.settlement.withLock { $0 }
    }

    public func control(_ control: ActionControl, owner: ExecutionOwner) async throws -> ActionControlReceipt? {
        try admission.check()
        guard UUID(uuidString: control.executionID) != nil, control.controlSequence > 0 else {
            throw SignalTransportError.invalidEnvelope
        }
        let bytes = try JSONEncoder().encode(control).count
        guard bytes <= 1024 else { throw SignalTransportError.invalidEnvelope }
        let admitted = activeControls.withLock { active in
            guard active < 16 else { return false }
            active += 1
            return true
        }
        guard admitted else { return .init(control, status: .busy) }
        defer { activeControls.withLock { $0 -= 1 } }
        let source = try await signals.executionEndpoint(address: owner.endpoint, incarnation: owner.incarnation)
        let target = try await actionEndpoint()
        let delivery = ActionControlDelivery(control: control)
        do {
            try await signals.send(
                source: source, target: target,
                envelope: .init(
                    id: control.controlID.uuidString, sessionID: owner.sessionID, contract: Contract.actionControl,
                    channel: Self.actionControlChannel,
                    payloadBytes: bytes, control: true),
                payload: delivery)
        } catch SignalTransportError.capacityExceeded {
            return .init(control, status: .busy)
        }
        return delivery.response.withLock { $0 }
    }
    public func finish(scope: ActionSchedulingScope, source: String) async throws {
        try await engine.finish(scope: scope, source: source)
    }
    public func cancel(scope: ActionSchedulingScope, source: String) async {
        await engine.cancel(scope: scope, source: source)
    }
    public func cancel(sessionID: String) async { await engine.cancel(sessionID: sessionID) }
    @discardableResult public func cancel(endpoint: String, incarnation: String, sessionID: String?) async -> Bool {
        await engine.cancel(endpoint: endpoint, incarnation: incarnation, sessionID: sessionID)
    }
    public func execute(_ input: FunctionInvocation, owner: ExecutionOwner) async throws -> ActionCompletion {
        try admission.check()
        let source = try await signals.executionEndpoint(address: owner.endpoint, incarnation: owner.incarnation)
        let target = try await actionEndpoint()
        let delivery = ToolCallDelivery(invocation: input)
        let bytes = input.call.parameters.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        try await signals.send(
            source: source, target: target,
            envelope: .init(
                id: input.executionID, sessionID: owner.sessionID, contract: Contract.toolCall,
                channel: Self.toolCallChannel, payloadBytes: bytes),
            payload: ToolDelivery.invoke(delivery), timeout: .seconds(120))
        return try delivery.result.result()
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
    public func finish(scope: ActionSchedulingScope, source: String) async throws {}
    public func cancel(scope: ActionSchedulingScope, source: String) async {}
    public func cancel(sessionID: String) async {}
    @discardableResult public func cancel(endpoint: String, incarnation: String, sessionID: String?) async -> Bool {
        true
    }
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
