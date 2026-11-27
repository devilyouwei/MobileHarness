import AgentCore
import Foundation
import FunctionContracts
import Gateway
import Synchronization

/// Agents' client for the Actions execution endpoint. App injects the separate execution management port.
public final class ActionExecutionTransport: ActionExecutionEngine {
    private struct Contracts: Sendable {
        let action: SignalRequestProtocol<ActionCallSignal, CallReply>
        let tool: SignalRequestProtocol<ToolCallSignal, CallReply>
        let control: SignalRequestProtocol<ActionControl, ActionControlReceipt?>

        init() throws {
            action = try .init(
                id: ActionCallSignal.contract, maximumRequestBytes: ActionInvocationSnapshot.maximumBytes,
                maximumReplyBytes: nil,
                requestSize: { signal in
                    switch signal {
                    case .call(let action):
                        Self.bytes(action.call.parameters) + action.call.actionPath.description.utf8.count
                    case .round(let round): Self.bytes(round)
                    }
                })
            tool = try .init(
                id: ToolCallSignal.contract, maximumRequestBytes: ActionInvocationSnapshot.maximumBytes,
                maximumReplyBytes: nil, timeout: .seconds(120),
                requestSize: { signal in
                    switch signal {
                    case .call(let tool): Self.bytes(tool.call.parameters)
                    case .round(let round): Self.bytes(round)
                    }
                })
            control = try .init(
                id: "action.control.v1", maximumRequestBytes: 1024, maximumReplyBytes: nil,
                requestSize: { try JSONEncoder().encode($0).count })
        }

        private static func bytes(_ values: [String: String]) -> Int {
            values.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        }
        private static func bytes(_ round: CallRoundBoundary) -> Int {
            round.roundID.utf8.count + round.scope.rawValue.utf8.count
        }
    }

    private final class PendingToolResults: Sendable {
        struct Key: Hashable, Sendable {
            let owner: ExecutionOwner
            let executionID: String
            let inputID: String
            let roundID: String?
        }

        private enum Entry: Sendable {
            case waiting
            case received(Result<ActionCompletion, any Error>)
        }

        private let entries = Mutex<[Key: Entry]>([:])

        func reserve(_ key: Key) throws {
            try entries.withLock { entries in
                guard entries.count < 256 else { throw SignalTransportError.capacityExceeded }
                guard entries[key] == nil else { throw SignalTransportError.invalidEnvelope }
                entries[key] = .waiting
            }
        }

        func receive(_ result: ToolExecutionResult) throws {
            try entries.withLock { entries in
                let key = Key(
                    owner: result.owner, executionID: result.executionID, inputID: result.inputID,
                    roundID: result.roundID)
                guard let entry = entries[key] else { throw CommunicationError.scopeClosed }
                if case .waiting = entry { entries[key] = .received(result.outcome) }
            }
        }

        func completion(_ key: Key) throws -> ActionCompletion {
            let entry = entries.withLock { $0[key] }
            guard case .received(let outcome) = entry else { throw SignalTransportError.invalidReply }
            return try outcome.get()
        }

        func release(_ key: Key) { entries.withLock { $0[key] = nil } }
    }

    private let management: any ActionExecutionManagement
    private let admission: GatewayAdmission
    private let signals: SignalTransport
    private let actionsEndpoint: SignalEndpoint
    private let contracts: Contracts
    private let pendingToolResults: PendingToolResults
    private let activeControls = Mutex(0)

    private init(
        management: any ActionExecutionManagement, ports: GatewayCapabilities, target: SignalEndpoint,
        contracts: Contracts, pendingToolResults: PendingToolResults
    ) {
        self.management = management
        admission = ports.admission
        signals = ports.signals
        actionsEndpoint = target
        self.contracts = contracts
        self.pendingToolResults = pendingToolResults
    }

    /// The host connects the Actions receiver to registered communication ports at composition.
    public static func connect(
        ports: GatewayCapabilities, engine: any ActionExecutionHost,
        receiveActionResult: @escaping @Sendable (ExecutionResult, ContinuousClock.Instant?) async throws -> Void = {
            _, _ in throw CommunicationError.scopeClosed
        },
        deliverStart: @escaping @Sendable (ExecutionStart) async -> ActionResultDelivery = { _ in .closed },
        deliverControl: @escaping @Sendable (ActionControlFeedback) async -> ActionResultDelivery = { _ in .closed }
    ) async throws -> ActionExecutionTransport {
        let signals = ports.signals
        let contracts = try Contracts()
        let pendingToolResults = PendingToolResults()
        let target = try await signals.register(
            address: "actions.execution", incarnation: UUID().uuidString, replaceExisting: false
        ) { _ in
            throw SignalTransportError.unsupportedProtocol
        }
        var feedbackEndpoint: SignalEndpoint?
        do {
            let feedback = try await signals.register(
                address: "agents.execution.results", incarnation: UUID().uuidString, replaceExisting: false
            ) { signal in
                guard signal.source == target else { throw CommunicationError.unauthorized }
                switch signal.payload {
                case let result as CallResultSignal:
                    guard signal.envelope.contract == CallResultSignal.contract,
                        signal.envelope.channel == CallResultSignal.channel, signal.envelope.id == result.executionID,
                        signal.envelope.sessionID == result.owner.sessionID
                    else { throw CommunicationError.invalidPayload }
                    switch result {
                    case .action(let result): try await receiveActionResult(result, signal.envelope.expiresAt)
                    case .tool(let result): try pendingToolResults.receive(result)
                    }
                case let event as ActionExecutionEventSignal:
                    guard signal.envelope.contract == ActionExecutionEventSignal.contract,
                        signal.envelope.channel == ActionExecutionEventSignal.channel,
                        signal.envelope.id == event.executionID, signal.envelope.sessionID == event.owner.sessionID
                    else { throw CommunicationError.invalidPayload }
                    let delivery: ActionResultDelivery
                    switch event {
                    case .started(let started): delivery = await deliverStart(started)
                    case .control(let control): delivery = await deliverControl(control)
                    }
                    switch delivery {
                    case .accepted: return
                    case .retry: throw CommunicationError.capacityExceeded
                    case .closed: throw CommunicationError.scopeClosed
                    }
                default: throw CommunicationError.invalidPayload
                }
            }
            feedbackEndpoint = feedback
            let deliver: @Sendable (CallResultSignal) async -> ActionResultDelivery = {
                await sendFeedback(
                    $0, owner: $0.owner, executionID: $0.executionID, contract: CallResultSignal.contract,
                    channel: CallResultSignal.channel, from: target, to: feedback, over: signals)
            }
            let deliverEvent: @Sendable (ActionExecutionEventSignal) async -> ActionResultDelivery = {
                await sendFeedback(
                    $0, owner: $0.owner, executionID: $0.executionID, contract: ActionExecutionEventSignal.contract,
                    channel: ActionExecutionEventSignal.channel, from: target, to: feedback, over: signals)
            }
            let receiver = ActionExecutionEndpoint(engine: engine, deliverResult: deliver)
            try await signals.registerContextualRequest(contracts.action, endpoint: target) { request, context in
                try await receiver.receive(request, owner: owner(of: context))
            }
            try await signals.registerContextualRequest(contracts.tool, endpoint: target) { request, context in
                try await receiver.receive(request, owner: owner(of: context))
            }
            try await signals.registerContextualRequest(contracts.control, endpoint: target) { request, context in
                try await receiver.receive(request, owner: owner(of: context))
            }
            try engine.bindSignals(
                .init(
                    validate: { invocation, owner in
                        guard let owner else { throw ActionExecutionError.invalidInvocation }
                        _ = try await signals.endpoint(address: owner.endpoint, incarnation: owner.incarnation)
                        guard invocation.context.source == owner.endpoint,
                            invocation.context.sessionID == owner.sessionID,
                            !owner.sessionID.isEmpty, owner.sessionID.utf8.count <= 128,
                            !invocation.context.inputID.isEmpty, invocation.context.inputID.utf8.count <= 128
                        else { throw ActionExecutionError.invalidInvocation }
                    },
                    deliver: deliver,
                    deliverStart: { await deliverEvent(.started($0)) },
                    deliverControl: { await deliverEvent(.control($0)) }))
        } catch {
            if let feedbackEndpoint { await signals.unregister(feedbackEndpoint) }
            await signals.unregister(target)
            throw error
        }
        return ActionExecutionTransport(
            management: engine, ports: ports, target: target, contracts: contracts,
            pendingToolResults: pendingToolResults)
    }

    private static func sendFeedback(
        _ payload: any Sendable, owner: ExecutionOwner, executionID: String, contract: String, channel: String,
        from source: SignalEndpoint, to target: SignalEndpoint,
        over signals: SignalTransport
    ) async -> ActionResultDelivery {
        do {
            _ = try await signals.endpoint(address: owner.endpoint, incarnation: owner.incarnation)
            try await signals.send(
                source: source, target: target,
                envelope: .init(
                    id: executionID, sessionID: owner.sessionID, contract: contract,
                    channel: channel, payloadBytes: 0, cleanup: true),
                payload: payload)
            return .accepted
        } catch SignalTransportError.capacityExceeded, SignalTransportError.expired,
            CommunicationError.capacityExceeded, CommunicationError.expired
        {
            return .retry
        } catch {
            return .closed
        }
    }

    private static func owner(of context: SignalRequestContext) -> ExecutionOwner {
        .init(
            endpoint: context.source.address, incarnation: context.source.incarnation,
            sessionID: context.envelope.sessionID)
    }

    private func request<Request: Sendable, Reply: Sendable>(
        _ payload: Request, using contract: SignalRequestProtocol<Request, Reply>, channel: String,
        id: String, owner: ExecutionOwner, control: Bool = false, expiresAt: ContinuousClock.Instant? = nil
    ) async throws -> Reply {
        try admission.check()
        let source = try await signals.endpoint(address: owner.endpoint, incarnation: owner.incarnation)
        return try await signals.request(
            source: source, target: actionsEndpoint, using: contract, request: payload,
            envelope: .init(
                id: id, sessionID: owner.sessionID, contract: contract.id, channel: channel, payloadBytes: 0,
                expiresAt: expiresAt, control: control))
    }

    public func enqueue(invocation: ScheduledAction) async throws -> String {
        guard let owner = invocation.owner else { throw ActionExecutionError.invalidInvocation }
        guard
            case .acknowledged(let id) = try await request(
                .call(invocation), using: contracts.action, channel: ActionCallSignal.channel,
                id: invocation.executionID, owner: owner)
        else { throw SignalTransportError.invalidReply }
        return id
    }

    public func schedule(_ directive: ExecutionSchedulingDirective, envelope: ExecutionEnvelope) async throws {
        try admission.check()
        let source = try await signals.endpoint(address: envelope.source)
        let owner = ExecutionOwner(
            endpoint: source.address, incarnation: source.incarnation, sessionID: envelope.sessionID)
        try await schedule(directive, envelope: envelope, owner: owner)
    }

    public func roundBoundary(
        _ boundary: CallRoundBoundary, lane: CallLane, owner: ExecutionOwner
    ) async throws -> CallRoundSettlement? {
        let id = UUID().uuidString
        switch lane {
        case .action:
            guard
                case .round(let settlement) = try await request(
                    .round(boundary), using: contracts.action, channel: ActionCallSignal.channel, id: id, owner: owner)
            else { throw SignalTransportError.invalidReply }
            return settlement
        case .tool:
            guard
                case .round(let settlement) = try await request(
                    .round(boundary), using: contracts.tool, channel: ToolCallSignal.channel, id: id, owner: owner,
                    expiresAt: .now.advanced(by: .seconds(30)))
            else { throw SignalTransportError.invalidReply }
            return settlement
        }
    }

    public func control(_ control: ActionControl, owner: ExecutionOwner) async throws -> ActionControlReceipt? {
        try admission.check()
        let admitted = activeControls.withLock { active in
            guard active < 16 else { return false }
            active += 1
            return true
        }
        guard admitted else { return .init(control, status: .busy) }
        defer { activeControls.withLock { $0 -= 1 } }
        do {
            return try await request(
                control, using: contracts.control, channel: "action.control", id: control.controlID.uuidString,
                owner: owner, control: true)
        } catch SignalTransportError.capacityExceeded {
            return .init(control, status: .busy)
        }
    }

    public func execute(_ input: FunctionInvocation, owner: ExecutionOwner) async throws -> ActionCompletion {
        let key = PendingToolResults.Key(
            owner: owner, executionID: input.executionID, inputID: input.context.inputID, roundID: input.roundID)
        try pendingToolResults.reserve(key)
        defer { pendingToolResults.release(key) }
        guard
            case .acknowledged(let id) = try await request(
                .call(input), using: contracts.tool, channel: ToolCallSignal.channel, id: input.executionID,
                owner: owner), id == input.executionID
        else { throw SignalTransportError.invalidReply }
        return try pendingToolResults.completion(key)
    }

    // These host-injected management operations retain their existing join and cleanup behavior.
    public func finish(scope: ActionSchedulingScope, source: String) async throws {
        try await management.finish(scope: scope, source: source)
    }
    public func cancel(scope: ActionSchedulingScope, source: String) async {
        await management.cancel(scope: scope, source: source)
    }
    public func cancel(sessionID: String) async { await management.cancel(sessionID: sessionID) }
    @discardableResult public func cancel(endpoint: String, incarnation: String, sessionID: String?) async -> Bool {
        await management.cancel(endpoint: endpoint, incarnation: incarnation, sessionID: sessionID)
    }
    public func requiredResources(for call: FunctionRequest) async throws -> Set<ResourceID> {
        try await management.requiredResources(for: call)
    }
    public func finishRoundDelivery(_ roundID: String) async throws {
        try await management.finishRoundDelivery(roundID)
    }
    public func executionSnapshot() async -> ActionExecutionSnapshot { await management.executionSnapshot() }
    public func lease(for owner: ExecutionOwner, resources: Set<ResourceID>) async -> ResourceLease? {
        await management.lease(for: owner, resources: resources)
    }
    public func acquireLease(resources: Set<ResourceID>, owner: ExecutionOwner, duration: Duration) async throws
        -> ResourceLease
    {
        try admission.check()
        return try await management.acquireLease(resources: resources, owner: owner, duration: duration)
    }
    public func renewLease(_ lease: ResourceLease, owner: ExecutionOwner, duration: Duration) async throws
        -> ResourceLease
    {
        try admission.check()
        return try await management.renewLease(lease, owner: owner, duration: duration)
    }
    public func releaseLease(_ lease: ResourceLease, owner: ExecutionOwner) async throws {
        try await management.releaseLease(lease, owner: owner)
    }
    public func closeResources(endpoint: String, incarnation: String) async {
        await management.closeResources(endpoint: endpoint, incarnation: incarnation)
    }
    public func closeResources(sessionID: String) async { await management.closeResources(sessionID: sessionID) }
}

/// Stand-in for isolated observation scopes that have no Actions attached: every invocation is rejected.
public struct DetachedActionExecution: ActionExecutionHost {
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
