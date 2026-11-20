import Foundation
import FunctionContracts

/// Internal Signal (Agent–Agent) envelope; Agent–Action execution uses ExecutionEnvelope instead.
public struct SignalEnvelope: Sendable {
    public let id: String
    public let sessionID: String
    public let contract: String
    public let version: Int
    public let hops: Int
    public let payloadBytes: Int
    public let expiresAt: ContinuousClock.Instant?
    public let control: Bool
    public let cleanup: Bool
    public init(
        id: String, sessionID: String, contract: String, version: Int = 1, hops: Int = 0,
        payloadBytes: Int, expiresAt: ContinuousClock.Instant? = nil, cleanup: Bool = false, control: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.contract = contract
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
    case unsupportedProtocol, duplicateProtocol, schemaMismatch, invalidReply, cyclicRequest
}

private enum SignalDispatchOwnership { @TaskLocal static var current: UUID? }

/// Internal Signal (Agent–Agent) transport. Opaque endpoint delivery: payload contracts and receiver policy belong to the endpoint owner.
public actor SignalTransport {
    private struct Endpoint {
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
    private var deliveries: [UUID: Delivery] = [:]
    private var active = 0
    private var bytes = 0
    private var closed = false
    public init(admission: GatewayAdmission? = nil, eventConfiguration: SignalEventConfiguration = .standard) {
        self.admission = admission
        self.eventConfiguration = eventConfiguration
    }
    public func register(
        address: String, incarnation: String,
        receive: @escaping @Sendable (GatewaySignal) async throws -> Void
    ) async throws -> SignalEndpoint {
        guard !closed else { throw SignalTransportError.closed }
        guard !address.isEmpty, address.utf8.count <= 64, !incarnation.isEmpty, incarnation.utf8.count <= 128 else {
            throw SignalTransportError.invalidEnvelope
        }
        guard endpoints[address] != nil || endpoints.count < 128 else { throw SignalTransportError.capacityExceeded }
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
    public func validateExecution(_ input: FunctionInvocation, owner: ExecutionOwner?) throws {
        guard !closed else { throw SignalTransportError.closed }
        guard let owner, let endpoint = endpoints[owner.endpoint]?.port,
            endpoint.incarnation == owner.incarnation
        else { throw SignalTransportError.staleEndpoint }
        guard input.context.source == owner.endpoint, input.context.sessionID == owner.sessionID,
            !owner.sessionID.isEmpty, owner.sessionID.utf8.count <= 128,
            !input.context.inputID.isEmpty, input.context.inputID.utf8.count <= 128
        else {
            throw SignalTransportError.invalidEnvelope
        }
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
    public func send(
        source: SignalEndpoint?, target: SignalEndpoint, envelope: SignalEnvelope,
        payload: any Sendable
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
        defer {
            active -= 1
            bytes -= envelope.payloadBytes
        }
        let id = UUID()
        let task = Task {
            try await SignalDispatchOwnership.$current.withValue(id) {
                try Task.checkCancellation()
                try self.validateEndpoint(source, target: target)
                if let request = payload as? SignalRequestInvocation {
                    try await request.operation()
                } else {
                    try await receiver.receive(GatewaySignal(source: source, envelope: envelope, payload: payload))
                }
                try Task.checkCancellation()
                try self.validateEndpoint(source, target: target)
            }
        }
        deliveries[id] = Delivery(source: source, target: target, cleanup: envelope.cleanup, task: task)
        defer { deliveries[id] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    func validateEnvelope(_ envelope: SignalEnvelope) throws {
        guard !closed else { throw SignalTransportError.closed }
        if !envelope.cleanup { try admission?.check() }
        guard envelope.version == 1, (0...8).contains(envelope.hops),
            !envelope.id.isEmpty, envelope.id.utf8.count <= 128,
            !envelope.sessionID.isEmpty, envelope.sessionID.utf8.count <= 128,
            !envelope.contract.isEmpty, envelope.contract.utf8.count <= 128,
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
        let pending = deliveries.values.filter { !$0.cleanup }
        for delivery in pending { delivery.task.cancel() }
        for delivery in pending { _ = await delivery.task.result }
    }
    func shutdown() async {
        closed = true
        await eventFacility?.shutdown()
        let pending = Array(deliveries.values)
        for delivery in pending { delivery.task.cancel() }
        for delivery in pending { _ = await delivery.task.result }
        endpoints.removeAll()
        requestHandlers.removeAll()
    }
}
