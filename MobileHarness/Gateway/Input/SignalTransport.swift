import Foundation

/// Addressed internal signal metadata; application payloads belong to the endpoint owners.
public struct SignalEnvelope: Sendable {
    public let id: String
    public let sessionID: String
    public let contract: String
    public let channel: String
    public let version: Int
    public let hops: Int
    public let payloadBytes: Int
    public let expiresAt: ContinuousClock.Instant?
    public let control: Bool
    public let cleanup: Bool
    public init(
        id: String, sessionID: String, contract: String, channel: String? = nil, version: Int = 1, hops: Int = 0,
        payloadBytes: Int, expiresAt: ContinuousClock.Instant? = nil, cleanup: Bool = false, control: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.contract = contract
        self.channel = channel ?? contract
        self.version = version
        self.hops = hops
        self.payloadBytes = payloadBytes
        self.expiresAt = expiresAt
        self.control = control
        self.cleanup = cleanup
    }
}
public struct SignalEndpoint: Hashable, Sendable {
    public let address: String
    public let incarnation: String
    fileprivate let token: UUID
}
public struct GatewaySignal: Sendable {
    public let source: SignalEndpoint?
    public let envelope: SignalEnvelope
    public let payload: any Sendable
}
public enum SignalTransportError: Error, Sendable {
    case invalidEnvelope, expired, closed, capacityExceeded, unknownEndpoint, staleEndpoint
    case unsupportedProtocol, duplicateProtocol, duplicateEndpoint, schemaMismatch, invalidReply, cyclicRequest
}

private enum SignalDispatchOwnership {
    @TaskLocal static var current: UUID?
}

/// Internal Signal transport. Opaque endpoint delivery: payload contracts and receiver policy belong to the endpoint owner.
public actor SignalTransport {
    private struct Endpoint: Sendable {
        let port: SignalEndpoint
        let receive: @Sendable (GatewaySignal) async throws -> Void
    }
    private let admission: GatewayAdmission?
    private let eventConfiguration: SignalEventConfiguration
    private var eventFacility: SignalEventTransport?
    public func events() throws -> SignalEventTransport {
        guard !closed else { throw SignalTransportError.closed }
        if let eventFacility { return eventFacility }
        let facility = SignalEventTransport(transport: self, admission: admission, configuration: eventConfiguration)
        eventFacility = facility
        return facility
    }
    public func stateSnapshot() async throws -> GatewayStateSnapshot {
        try Task.checkCancellation()
        let events = await eventFacility?.runtimeCounts() ?? [:]
        var runtime: [String: GatewayStateSnapshot.Value] = [
            "endpoints": .count(endpoints.count), "deliveries": .count(deliveries.count),
            "active": .count(active), "bytes": .count(bytes),
            "closed": .flag(closed), "eventFacility": .flag(eventFacility != nil),
        ]
        runtime.merge(events) { _, current in current }
        return GatewayStateSnapshot(path: "gateway.signals", runtime: runtime)
    }
    private var endpoints: [String: Endpoint] = [:]
    var requestHandlers: [SignalEndpoint: [String: SignalRequestHandler]] = [:]
    func validateRequestEndpoint(_ endpoint: SignalEndpoint) throws {
        guard !closed else { throw SignalTransportError.closed }
        guard endpoints[endpoint.address]?.port == endpoint else { throw SignalTransportError.staleEndpoint }
    }
    private struct Delivery {
        let source: SignalEndpoint?
        let target: SignalEndpoint
        let cleanup: Bool
        let task: Task<Void, any Error>
    }
    private enum SendCompletion: Sendable {
        case receiver(Result<Void, any Error>)
        case deadline
        case timerCancelled
    }
    private var deliveries: [UUID: Delivery] = [:]
    private var active = 0
    private var bytes = 0
    private var closed = false
    public init(admission: GatewayAdmission? = nil, eventConfiguration: SignalEventConfiguration = .standard) {
        self.admission = admission
        self.eventConfiguration = eventConfiguration
    }
    public func register(
        address: String, incarnation: String, replaceExisting: Bool = true,
        receive: @escaping @Sendable (GatewaySignal) async throws -> Void
    ) async throws -> SignalEndpoint {
        guard !closed else { throw SignalTransportError.closed }
        guard !address.isEmpty, address.utf8.count <= 64, !incarnation.isEmpty, incarnation.utf8.count <= 128 else {
            throw SignalTransportError.invalidEnvelope
        }
        guard endpoints[address] != nil || endpoints.count < 128 else { throw SignalTransportError.capacityExceeded }
        guard replaceExisting || endpoints[address] == nil else { throw SignalTransportError.duplicateEndpoint }
        if let existing = endpoints[address], existing.port.incarnation == incarnation { return existing.port }
        let retired = endpoints[address]?.port
        if let retired {
            requestHandlers[retired] = nil
            for delivery in deliveries.values where delivery.source == retired || delivery.target == retired {
                delivery.task.cancel()
            }
        }
        let port = SignalEndpoint(address: address, incarnation: incarnation, token: UUID())
        endpoints[address] = Endpoint(port: port, receive: receive)
        if let retired { await eventFacility?.unregister(retired) }
        try validateRequestEndpoint(port)
        return port
    }
    public func endpoint(address: String, incarnation: String? = nil) throws -> SignalEndpoint {
        guard !closed, let endpoint = endpoints[address]?.port,
            incarnation == nil || endpoint.incarnation == incarnation
        else { throw SignalTransportError.staleEndpoint }
        return endpoint
    }

    public func unregister(_ endpoint: SignalEndpoint) async {
        guard endpoints[endpoint.address]?.port == endpoint else { return }
        endpoints[endpoint.address] = nil
        await eventFacility?.unregister(endpoint)
        requestHandlers[endpoint] = nil
        let pending = deliveries.filter { $0.value.source == endpoint || $0.value.target == endpoint }
        for delivery in pending.values { delivery.task.cancel() }
        for (id, delivery) in pending where id != SignalDispatchOwnership.current { _ = await delivery.task.result }
    }
    public func unregister(address: String, incarnation: String) async {
        guard let endpoint = endpoints[address]?.port, endpoint.incarnation == incarnation else { return }
        await unregister(endpoint)
    }
    /// Directed delivery acknowledges the receiver's return and bounds the whole request.
    public func send(
        source: SignalEndpoint?, target: SignalEndpoint, envelope: SignalEnvelope,
        payload: any Sendable, timeout: Duration = .seconds(30)
    ) async throws {
        guard timeout > .zero, timeout <= .seconds(120) else { throw SignalTransportError.invalidEnvelope }
        let latest = ContinuousClock.now.advanced(by: timeout)
        let deadline = envelope.expiresAt.map { min($0, latest) } ?? latest
        let addressed = SignalEnvelope(
            id: envelope.id, sessionID: envelope.sessionID, contract: envelope.contract, channel: envelope.channel,
            version: envelope.version, hops: envelope.hops, payloadBytes: envelope.payloadBytes, expiresAt: deadline,
            cleanup: envelope.cleanup, control: envelope.control)
        try await deliver(source: source, target: target, envelope: addressed, payload: payload, deadline: deadline)
    }

    /// Pub/Sub tracks branch lifetime and expiry independently and does not wait for a reply.
    func deliverEvent(
        source: SignalEndpoint, target: SignalEndpoint, envelope: SignalEnvelope, payload: any Sendable
    ) async throws {
        try await deliver(source: source, target: target, envelope: envelope, payload: payload, deadline: nil)
    }

    private func deliver(
        source: SignalEndpoint?, target: SignalEndpoint, envelope: SignalEnvelope,
        payload: any Sendable, deadline: ContinuousClock.Instant?
    ) async throws {
        try Task.checkCancellation()
        try validateEnvelope(envelope)
        if let source, endpoints[source.address]?.port != source { throw SignalTransportError.staleEndpoint }
        guard let receiver = endpoints[target.address], receiver.port == target else {
            throw SignalTransportError.staleEndpoint
        }
        // Ordinary traffic cannot consume the reserve needed for trusted cleanup delivery.
        let slotLimit = envelope.cleanup || envelope.control ? 256 : 240
        let byteLimit = envelope.cleanup || envelope.control ? 8 * 1024 * 1024 : 8 * 1024 * 1024 - 256 * 1024
        guard active < slotLimit, envelope.payloadBytes <= byteLimit - bytes else {
            throw SignalTransportError.capacityExceeded
        }
        active += 1
        bytes += envelope.payloadBytes
        let id = UUID()
        defer {
            deliveries[id] = nil
            active -= 1
            bytes -= envelope.payloadBytes
        }

        let task = Task {
            try await SignalDispatchOwnership.$current.withValue(id) {
                if let deadline {
                    try await withTaskGroup(of: SendCompletion.self) { group in
                        group.addTask {
                            do {
                                try await self.deliverToEndpoint(
                                    receiver, source: source, envelope: envelope, payload: payload, deadline: deadline)
                                return .receiver(.success(()))
                            } catch {
                                return .receiver(.failure(error))
                            }
                        }
                        group.addTask {
                            do {
                                try await Task.sleep(until: deadline, clock: .continuous)
                                return .deadline
                            } catch {
                                return .timerCancelled
                            }
                        }
                        defer { group.cancelAll() }
                        for await completion in group {
                            switch completion {
                            case .receiver(let result): return result
                            case .deadline: return .failure(SignalTransportError.expired)
                            case .timerCancelled: continue
                            }
                        }
                        return .failure(CancellationError())
                    }.get()
                } else {
                    try await deliverToEndpoint(
                        receiver, source: source, envelope: envelope, payload: payload, deadline: nil)
                }
            }
        }
        deliveries[id] = Delivery(source: source, target: target, cleanup: envelope.cleanup, task: task)
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func deliverToEndpoint(
        _ receiver: Endpoint, source: SignalEndpoint?, envelope: SignalEnvelope,
        payload: any Sendable, deadline: ContinuousClock.Instant?
    ) async throws {
        try Task.checkCancellation()
        try validateEndpoint(source, target: receiver.port)
        try validateEnvelope(envelope)
        if let deadline, deadline <= .now { throw SignalTransportError.expired }
        if let request = payload as? SignalRequestInvocation {
            try await request.operation()
        } else {
            try await receiver.receive(GatewaySignal(source: source, envelope: envelope, payload: payload))
        }
        try Task.checkCancellation()
        try validateEndpoint(source, target: receiver.port)
        if let deadline, deadline <= .now { throw SignalTransportError.expired }
    }

    func validateEnvelope(_ envelope: SignalEnvelope) throws {
        guard !closed else { throw SignalTransportError.closed }
        if !envelope.cleanup { try admission?.check() }
        guard envelope.version == 1, (0...8).contains(envelope.hops),
            !envelope.id.isEmpty, envelope.id.utf8.count <= 128,
            !envelope.sessionID.isEmpty, envelope.sessionID.utf8.count <= 128,
            !envelope.contract.isEmpty, envelope.contract.utf8.count <= 128,
            !envelope.channel.isEmpty, envelope.channel.utf8.count <= 256,
            envelope.payloadBytes >= 0, envelope.payloadBytes <= 8 * 1024 * 1024
        else { throw SignalTransportError.invalidEnvelope }
        if let expiry = envelope.expiresAt, expiry <= .now { throw SignalTransportError.expired }
    }
    private func validateEndpoint(_ source: SignalEndpoint?, target: SignalEndpoint) throws {
        guard !closed, endpoints[target.address]?.port == target else { throw SignalTransportError.staleEndpoint }
        if let source, endpoints[source.address]?.port != source { throw SignalTransportError.staleEndpoint }
    }
    func suspend() async {
        await eventFacility?.suspend()
        let pending = deliveries.filter { !$0.value.cleanup }
        for delivery in pending.values { delivery.task.cancel() }
        for (id, delivery) in pending where id != SignalDispatchOwnership.current { _ = await delivery.task.result }
    }
    func shutdown() async {
        closed = true
        await eventFacility?.shutdown()
        let pending = deliveries
        for delivery in pending.values { delivery.task.cancel() }
        for (id, delivery) in pending where id != SignalDispatchOwnership.current { _ = await delivery.task.result }
        endpoints.removeAll()
        requestHandlers.removeAll()
    }
}

/// Bounded producer admission before asynchronous authorization and publication.
/// Each selected channel has one worker. The producer supplies its business channel and admission order.
public struct SignalChannelDispatcher<Value: Sendable>: Sendable {
    private let queues: [String: AsyncStream<Value>.Continuation]
    private let streams: [AsyncStream<Value>]

    public init(channels: Set<String>, capacities: [String: Int] = [:]) {
        let entries = channels.sorted().map { channel in
            let capacity = min(max(capacities[channel] ?? 16, 1), 256)
            return (channel, AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingOldest(capacity)))
        }
        queues = Dictionary(uniqueKeysWithValues: entries.map { ($0.0, $0.1.continuation) })
        streams = entries.map { $0.1.stream }
    }

    public func enqueue(_ value: Value, channel: String) throws {
        guard let queue = queues[channel] else { throw SignalTransportError.unsupportedProtocol }
        switch queue.yield(value) {
        case .enqueued: return
        case .dropped: throw SignalTransportError.capacityExceeded
        case .terminated: throw SignalTransportError.closed
        @unknown default: throw SignalTransportError.closed
        }
    }

    public func dispatch(_ delivery: @escaping @Sendable (Value) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for stream in streams {
                group.addTask {
                    for await value in stream {
                        try Task.checkCancellation()
                        try await delivery(value)
                    }
                }
            }
            while try await group.next() != nil {}
        }
    }

    public func finish() {
        for queue in queues.values { queue.finish() }
    }
}

/// Gateway-owned admission for independent sends before asynchronous routing.
public actor SignalWorkPool {
    private var inFlight = 0

    public init() {}

    public func submit(
        _ operation: @escaping @Sendable () async throws -> Void
    ) throws -> Task<Void, any Error> {
        try Task.checkCancellation()
        guard inFlight < 128 else { throw SignalTransportError.capacityExceeded }
        inFlight += 1
        return Task {
            defer { inFlight -= 1 }
            try Task.checkCancellation()
            try await operation()
        }
    }
}
