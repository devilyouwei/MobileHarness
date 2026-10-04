import CoreBluetooth
import Foundation
import OSLog

public enum NexArmBluetoothPower: Sendable, Equatable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}
public enum NexArmBluetoothPhase: Sendable, Equatable { case disconnected, connecting, connected, disconnecting }
public struct NexArmBluetoothDevice: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public static func discoveryName(advertised: String?, cached: String?) -> String? {
        for value in [advertised, cached] {
            if let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            {
                return String(name.prefix(64))
            }
        }
        return nil
    }
    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}
/// Connection-local transport facts. Counters saturate; no command history is retained.
public struct NexArmBluetoothTraffic: Sendable, Equatable {
    public internal(set) var sentPackets: UInt64 = 0
    public internal(set) var sentBytes: UInt64 = 0
    public internal(set) var pacingDeferrals: UInt64 = 0
    public internal(set) var systemDeferrals: UInt64 = 0
    public internal(set) var flowControlResumptions: UInt64 = 0
    public internal(set) var notificationBytes: UInt64 = 0
    public internal(set) var feedbackSamples: UInt64 = 0
    public internal(set) var notificationGapMilliseconds = 0
    public internal(set) var feedbackGapMilliseconds = 0
    public internal(set) var longestNotificationGapMilliseconds = 0
    public internal(set) var longestFeedbackGapMilliseconds = 0
    public init() {}
}

/// One connection-wide budget for requests and both streaming modes; no queued packets.
struct NexArmBLETrafficBudget {
    static let minimumInterval: Duration = .milliseconds(30)
    private(set) var nextWrite: ContinuousClock.Instant?
    private(set) var statistics = NexArmBluetoothTraffic()
    private var lastNotification: ContinuousClock.Instant?
    private var lastFeedback: ContinuousClock.Instant?

    init(started: ContinuousClock.Instant = .now) {
        lastNotification = started
        lastFeedback = started
    }
    func diagnostics(at now: ContinuousClock.Instant = .now) -> NexArmBluetoothTraffic {
        var value = statistics
        if let lastNotification { value.notificationGapMilliseconds = milliseconds(now - lastNotification) }
        if let lastFeedback { value.feedbackGapMilliseconds = milliseconds(now - lastFeedback) }
        value.longestNotificationGapMilliseconds = max(
            value.longestNotificationGapMilliseconds, value.notificationGapMilliseconds)
        value.longestFeedbackGapMilliseconds = max(value.longestFeedbackGapMilliseconds, value.feedbackGapMilliseconds)
        return value
    }
    mutating func canSend(at now: ContinuousClock.Instant, systemReady: Bool) -> Bool {
        if !systemReady {
            increment(&statistics.systemDeferrals)
            return false
        }
        if let nextWrite, now < nextWrite {
            increment(&statistics.pacingDeferrals)
            return false
        }
        return true
    }
    mutating func sent(bytes: Int, at now: ContinuousClock.Instant) {
        increment(&statistics.sentPackets)
        increment(&statistics.sentBytes, by: UInt64(bytes))
        nextWrite = now.advanced(by: Self.minimumInterval)
    }
    mutating func received(bytes: Int, feedbackSamples: UInt64, at now: ContinuousClock.Instant) {
        if bytes > 0 {
            increment(&statistics.notificationBytes, by: UInt64(bytes))
            if let lastNotification {
                statistics.longestNotificationGapMilliseconds = max(
                    statistics.longestNotificationGapMilliseconds, milliseconds(now - lastNotification))
            }
            lastNotification = now
        }
        if feedbackSamples > 0 {
            increment(&statistics.feedbackSamples, by: feedbackSamples)
            if let lastFeedback {
                statistics.longestFeedbackGapMilliseconds = max(
                    statistics.longestFeedbackGapMilliseconds, milliseconds(now - lastFeedback))
            }
            lastFeedback = now
        }
    }
    mutating func resumed() { increment(&statistics.flowControlResumptions) }
    private func milliseconds(_ duration: Duration) -> Int {
        let value =
            Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        return Int(min(Double(Int.max / 2), max(0, value)))
    }
}

private func increment(_ value: inout UInt64, by amount: UInt64 = 1) {
    let result = value.addingReportingOverflow(amount)
    value = result.overflow ? .max : result.partialValue
}

public struct NexArmBluetoothSnapshot: Sendable, Equatable {
    public var power: NexArmBluetoothPower = .unknown
    public var phase: NexArmBluetoothPhase = .disconnected
    public var scanning = false
    public var traffic = NexArmBluetoothTraffic()
    public var feedbackHealthy = true
    public var devices: [NexArmBluetoothDevice] = []
    public var selected: NexArmBluetoothDevice?
    public var discoveryLimitReached = false
    public var failure: NexArmBluetoothFailure?
    public init() {}
}
public enum NexArmBluetoothError: Error, Sendable, Equatable {
    case unavailable, unknownDevice, incompatibleService, packetTooLarge
}
public protocol NexArmBluetoothLink: NexArmObservableLink {
    nonisolated var updates: AsyncStream<NexArmBluetoothSnapshot> { get }
    func status() async -> NexArmBluetoothSnapshot
    func scan() async throws
    func stopScan() async
    func beginLiveControl() async throws -> UUID
    func sendLive(_ packet: NexArmPacket, session: UUID) async throws -> Bool
    func endLiveControl(_ session: UUID) async
    func clearDiscovery() async
    func forgetDevice() async throws
    func connect(_ id: UUID) async throws
    func disconnect() async
}

/// Actor-facing transport; CoreBluetooth objects never leave their main-actor delegate owner.
public actor NexArmBluetooth: NexArmBluetoothLink, NexArmObservableLink {
    public nonisolated let updates: AsyncStream<NexArmBluetoothSnapshot>
    private let driver: Task<NexArmBLEDriver, Never>
    public init() {
        let pair = AsyncStream<NexArmBluetoothSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = pair.stream
        driver = Task { @MainActor in NexArmBLEDriver(updates: pair.continuation) }
    }
    public func beginObservation() async throws -> UUID { try await driver.value.beginObservation() }
    public func sendObserved(_ packet: NexArmPacket, session: UUID) async throws -> Bool {
        try await driver.value.sendObserved(packet, session: session)
    }
    public func latestObservation(after sequence: UInt64, session: UUID) async throws -> NexArmTelemetry? {
        try await driver.value.latestObservation(after: sequence, session: session)
    }
    public func endObservation(_ session: UUID) async { await driver.value.endObservation(session) }
    public func status() async -> NexArmBluetoothSnapshot { await driver.value.status() }
    public func scan() async throws { try await driver.value.scan() }
    public func stopScan() async { await driver.value.stopScan() }
    public func beginLiveControl() async throws -> UUID { try await driver.value.beginLiveControl() }
    public func sendLive(_ packet: NexArmPacket, session: UUID) async throws -> Bool {
        try await driver.value.sendLive(packet, session: session)
    }
    public func endLiveControl(_ session: UUID) async { await driver.value.endLiveControl(session) }
    public func clearDiscovery() async { await driver.value.clearDiscovery() }
    public func forgetDevice() async throws { try await driver.value.forgetDevice() }
    public func connect(_ id: UUID) async throws { try await driver.value.connect(id) }
    public func disconnect() async { await driver.value.disconnect() }
    public func close() async { await disconnect() }
    public func write(_ packet: NexArmPacket) async throws { try await driver.value.write(packet) }
    public func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) async throws
        -> NexArmPacket
    {
        try await driver.value.exchange(packet, replyID: replyID, replyCommand: replyCommand, replyCount: replyCount)
    }
}

/// Structured transport diagnostics; consumers own presentation and recovery advice.
public enum NexArmBluetoothStep: String, Sendable, Equatable {
    case connecting, services, characteristics, notifications, writing, response
}
public enum NexArmBluetoothFailure: Sendable, Equatable {
    case timeout(NexArmBluetoothStep)
    case responseTimeout(command: UInt8, expectedBytes: Int, receivedBytes: Int)
    case incompatibleService(NexArmBluetoothStep)
    case native(step: NexArmBluetoothStep, domain: String, code: Int)
    case disconnectUnconfirmed

    public init(step: NexArmBluetoothStep, error: any Error) {
        if error as? NexArmError == .timeout {
            self = .timeout(step)
        } else if error as? NexArmBluetoothError == .incompatibleService {
            self = .incompatibleService(step)
        } else {
            let native = error as NSError
            self = .native(step: step, domain: String(native.domain.prefix(256)), code: native.code)
        }
    }
}

/// One request, no pending queue. ACK and a matching decoded reply are both required.
struct NexArmBLEReply {
    let id: UInt8
    let command: UInt8
    let count: Int
    var readOnlyQuery = false
    var acknowledgmentOnly = false
    var acknowledged = false
    var response: NexArmPacket?
    var decoder = NexArmDecoder()
    var receivedBytes = 0
    mutating func receive(_ bytes: [UInt8]) throws {
        guard !acknowledgmentOnly else { return }
        receivedBytes += bytes.count
        guard receivedBytes <= 16_384 else { throw NexArmError.overflow }
        try decoder.append(bytes)
        while let packet = try decoder.next() {
            if packet.id == id && packet.command == command && packet.payload.count == count { response = packet }
        }
    }
    var completed: NexArmPacket? { acknowledged ? response : nil }
}

@MainActor
private final class NexArmBLEDriver: NSObject, @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate
{
    private var trafficBudget = NexArmBLETrafficBudget()
    private var telemetry = NexArmTelemetryCache()
    private var observationID: UUID?
    private var feedbackWatchdog: NexArmFeedbackWatchdog?
    private var feedbackMonitor: Task<Void, Never>?
    func beginObservation() throws -> UUID {
        guard snapshot.phase == .connected, let tx, rx?.isNotifying == true else { throw NexArmError.disconnected }
        guard snapshot.feedbackHealthy else { throw NexArmError.feedbackLost }
        guard liveControlID == nil, request == nil, observationID == nil else { throw NexArmError.busy }
        guard tx.properties.contains(.writeWithoutResponse) else { throw NexArmBluetoothError.incompatibleService }
        let token = UUID()
        observationID = token
        return token
    }
    func sendObserved(_ packet: NexArmPacket, session: UUID) throws -> Bool {
        try Task.checkCancellation()
        guard observationID == session, liveControlID == nil else { throw CancellationError() }
        guard snapshot.feedbackHealthy else { throw NexArmError.feedbackLost }
        guard snapshot.phase == .connected, let peripheral, let tx else { throw NexArmError.disconnected }
        guard packet.isObservedControl
        else { throw NexArmError.invalidPacket }
        guard packet.bytes.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            throw NexArmBluetoothError.packetTooLarge
        }
        let now = ContinuousClock.now
        guard trafficBudget.canSend(at: now, systemReady: peripheral.canSendWriteWithoutResponse) else { return false }
        peripheral.writeValue(Data(packet.bytes), for: tx, type: .withoutResponse)
        trafficBudget.sent(bytes: packet.bytes.count, at: .now)
        return true
    }
    func latestObservation(after sequence: UInt64, session: UUID) throws -> NexArmTelemetry? {
        guard observationID == session, liveControlID == nil else { throw CancellationError() }
        guard snapshot.feedbackHealthy else { throw NexArmError.feedbackLost }
        guard snapshot.phase == .connected else { throw NexArmError.disconnected }
        guard let latest = telemetry.latest, latest.sequence > sequence else { return nil }
        return latest
    }
    func endObservation(_ session: UUID) { if observationID == session { observationID = nil } }
    private static let service = CBUUID(string: "FFE0")
    private static let transmit = CBUUID(string: "FFE1")
    private static let receive = CBUUID(string: "FFE2")
    private let updates: AsyncStream<NexArmBluetoothSnapshot>.Continuation
    private var snapshot = NexArmBluetoothSnapshot()
    private let log = Logger(subsystem: "dev.mobileharness", category: "NexArmBLE")
    private var step = NexArmBluetoothStep.connecting {
        didSet { log.info("BLE step: \(self.step.rawValue, privacy: .public)") }
    }
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]  // 128 discovered devices, reject excess.
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var scanRequested = false
    private var scanTimer: Task<Void, Never>?
    private var connection: CheckedContinuation<Void, any Error>?
    private var connectionID: UUID?
    private var connectionTimer: Task<Void, Never>?
    private var request: CheckedContinuation<NexArmPacket, any Error>?
    private var requestID: UUID?
    private var requestWasSent = false
    private var reply: NexArmBLEReply?
    private var requestTimer: Task<Void, Never>?
    private var requestSender: Task<Void, Never>?
    private var queryTimeoutLatched = false
    private var liveControlID: UUID?
    private var retiredWriteAcknowledgment = false
    private var liveDrainUntil: ContinuousClock.Instant?
    private var disconnectTask: Task<Void, Never>?

    init(updates: AsyncStream<NexArmBluetoothSnapshot>.Continuation) {
        self.updates = updates
        super.init()
        publish()
    }
    // Replace only presentation snapshots, never commands/results.
    private func publish() {
        snapshot.traffic = trafficBudget.diagnostics()
        updates.yield(snapshot)
    }
    private func manager() -> CBCentralManager {
        if let central { return central }
        let value = CBCentralManager(delegate: self, queue: .main)
        central = value
        return value
    }
    func status() -> NexArmBluetoothSnapshot {
        var value = snapshot
        if snapshot.phase == .connected { value.traffic = trafficBudget.diagnostics() }
        return value
    }
    func scan() throws {
        try Task.checkCancellation()
        guard snapshot.phase == .disconnected else { throw NexArmError.busy }
        let central = manager()
        guard central.state == .unknown || central.state == .resetting || central.state == .poweredOn else {
            throw NexArmBluetoothError.unavailable
        }
        snapshot.failure = nil
        snapshot.discoveryLimitReached = false
        snapshot.devices = []
        peripherals = [:]
        scanRequested = true
        if central.state == .poweredOn { beginScan() }
    }
    private func beginScan() {
        scanTimer?.cancel()
        central?.scanForPeripherals(
            withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        snapshot.scanning = true
        publish()
        scanTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.stopScan()
        }
    }
    func stopScan() {
        scanRequested = false
        scanTimer?.cancel()
        scanTimer = nil
        central?.stopScan()
        snapshot.scanning = false
        publish()
    }
    func clearDiscovery() {
        stopScan()
        snapshot.devices = []
        snapshot.discoveryLimitReached = false
        peripherals = [:]
        publish()
    }
    func forgetDevice() throws {
        guard snapshot.phase == .disconnected, peripheral == nil else { throw NexArmError.busy }
        clearDiscovery()
        snapshot.selected = nil
        snapshot.failure = nil
        publish()
    }
    func connect(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard snapshot.phase == .disconnected, connection == nil, disconnectTask == nil else { throw NexArmError.busy }
        let central = manager()
        guard central.state == .poweredOn else { throw NexArmBluetoothError.unavailable }
        // Retrieval is only for a device explicitly selected by the host (e.g. a remembered device).
        guard let selected = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            throw NexArmBluetoothError.unknownDevice
        }
        stopScan()
        peripheral = selected
        selected.delegate = self
        snapshot.selected =
            snapshot.devices.first { $0.id == id } ?? .init(id: id, name: selected.name ?? "", rssi: 0)
        clearDiscovery()
        step = .connecting
        snapshot.phase = .connecting
        snapshot.failure = nil
        let token = UUID()
        connectionID = token
        publish()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection = continuation
                connectionTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    guard let self, self.connectionID == token else { return }
                    self.fail(NexArmError.timeout)
                }
                central.connect(selected)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == token else { return }
                self.fail(CancellationError())
            }
        }
        try Task.checkCancellation()
    }
    func beginLiveControl() throws -> UUID {
        observationID = nil
        guard snapshot.phase == .connected, let tx else { throw NexArmError.disconnected }
        guard tx.properties.contains(.writeWithoutResponse) else { throw NexArmBluetoothError.incompatibleService }
        let token = UUID()
        liveControlID = token
        // Retire an old observation instead of allowing its timeout to close a live jog.
        // Its late data is ignored while manual control owns the channel.
        if let pending = request {
            retiredWriteAcknowledgment = requestWasSent && !(reply?.acknowledged ?? true)
            requestTimer?.cancel()
            requestTimer = nil
            requestSender?.cancel()
            requestSender = nil
            request = nil
            requestID = nil
            requestWasSent = false
            reply = nil
            pending.resume(throwing: CancellationError())
        }
        return token
    }
    func sendLive(_ packet: NexArmPacket, session: UUID) throws -> Bool {
        try Task.checkCancellation()
        guard liveControlID == session else { throw CancellationError() }
        guard snapshot.phase == .connected, let peripheral, let tx else { throw NexArmError.disconnected }
        guard snapshot.feedbackHealthy else { throw NexArmError.feedbackLost }
        guard packet.isLiveControl else { throw NexArmError.invalidPacket }
        guard packet.bytes.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            throw NexArmBluetoothError.packetTooLarge
        }
        let now = ContinuousClock.now
        guard trafficBudget.canSend(at: now, systemReady: peripheral.canSendWriteWithoutResponse) else { return false }
        peripheral.writeValue(Data(packet.bytes), for: tx, type: .withoutResponse)
        trafficBudget.sent(bytes: packet.bytes.count, at: .now)
        return true  // Local transport admission only; no device-completion claim.
    }
    func endLiveControl(_ session: UUID) {
        if liveControlID == session {
            liveControlID = nil
            liveDrainUntil = .now.advanced(by: .milliseconds(150))
        }
    }
    func write(_ packet: NexArmPacket) async throws {
        _ = try await perform(
            packet, replyID: packet.id, replyCommand: packet.command, replyCount: 0, acknowledgmentOnly: true)
    }
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) async throws
        -> NexArmPacket
    {
        try await perform(
            packet, replyID: replyID, replyCommand: replyCommand, replyCount: replyCount, acknowledgmentOnly: false)
    }
    private func perform(
        _ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int,
        acknowledgmentOnly: Bool
    ) async throws -> NexArmPacket {
        try Task.checkCancellation()
        guard liveControlID == nil, observationID == nil else { throw CancellationError() }
        if let liveDrainUntil, ContinuousClock.now < liveDrainUntil {
            try await Task.sleep(until: liveDrainUntil, clock: .continuous)
        }
        try Task.checkCancellation()
        guard liveControlID == nil, observationID == nil else { throw CancellationError() }
        guard !retiredWriteAcknowledgment else { throw NexArmError.busy }
        guard snapshot.phase == .connected, let peripheral, let tx, rx?.isNotifying == true else {
            throw NexArmError.disconnected
        }
        guard request == nil else { throw NexArmError.busy }
        guard !queryTimeoutLatched else { throw NexArmError.timeout }
        guard (0...253).contains(replyCount),
            packet.bytes.count <= peripheral.maximumWriteValueLength(for: .withResponse)
        else {
            throw NexArmBluetoothError.packetTooLarge
        }
        step = .writing
        let token = UUID()
        requestID = token
        requestWasSent = false
        reply = NexArmBLEReply(
            id: replyID, command: replyCommand, count: replyCount,
            readOnlyQuery: packet.id == 255
                && (([1, 11].contains(packet.command) && packet.payload.isEmpty)
                    || (packet.command == 7 && packet.payload.count == 14)),
            acknowledgmentOnly: acknowledgmentOnly)
        // Internal completion token only; write() exposes no fabricated device reply.
        if acknowledgmentOnly { reply?.response = packet }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request = continuation
                requestTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, self.requestID == token else { return }
                    // No wire transaction IDs: close on timeout so late replies cannot satisfy another request.
                    self.fail(NexArmError.timeout)
                }
                // The request slot is already reserved, so the pacing wait cannot admit a second query.
                requestSender = Task { [weak self] in
                    guard let self else { return }
                    if let deadline = self.trafficBudget.nextWrite, ContinuousClock.now < deadline {
                        _ = self.trafficBudget.canSend(at: .now, systemReady: true)
                        do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    }
                    guard !Task.isCancelled, self.requestID == token,
                        self.snapshot.phase == .connected, self.peripheral === peripheral,
                        self.liveControlID == nil, self.observationID == nil
                    else { return }
                    self.requestWasSent = true
                    peripheral.writeValue(Data(packet.bytes), for: tx, type: .withResponse)
                    self.trafficBudget.sent(bytes: packet.bytes.count, at: .now)
                    self.requestSender = nil
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.requestID == token else { return }
                self.fail(CancellationError())
            }
        }
    }
    func disconnect() async {
        stopScan()
        failPending(CancellationError())
        guard let peripheral else { return }
        if let disconnectTask {
            await disconnectTask.value
            return
        }
        snapshot.phase = .disconnecting
        tx = nil
        rx = nil
        publish()
        central?.cancelPeripheralConnection(peripheral)
        let task = Task { [weak self] in
            // Keep admission fenced until CoreBluetooth confirms disconnection. Bound the caller's join.
            for _ in 0..<30 {
                if self?.peripheral == nil { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, self.peripheral != nil else { return }
            self.snapshot.failure = .disconnectUnconfirmed
            self.publish()
        }
        disconnectTask = task
        await task.value
        disconnectTask = nil
    }
    private func failPending(_ error: any Error) {
        observationID = nil
        telemetry = NexArmTelemetryCache()
        liveControlID = nil
        retiredWriteAcknowledgment = false
        liveDrainUntil = nil
        connectionTimer?.cancel()
        connectionTimer = nil
        requestTimer?.cancel()
        requestTimer = nil
        requestSender?.cancel()
        requestSender = nil
        let connecting = connection
        connection = nil
        connectionID = nil
        let pending = request
        request = nil
        requestID = nil
        requestWasSent = false
        reply = nil
        connecting?.resume(throwing: error)
        pending?.resume(throwing: error)
    }
    private func fail(_ error: any Error) {
        // Capture the pending query before failPending clears it. Never replay a timed-out request.
        let keepConnection =
            error as? NexArmError == .timeout && step == .response
            && reply?.readOnlyQuery == true
        let failure: NexArmBluetoothFailure?
        if error as? NexArmError == .timeout, step == .response, let reply, !reply.acknowledgmentOnly {
            failure = .responseTimeout(
                command: reply.command, expectedBytes: reply.count, receivedBytes: reply.receivedBytes)
        } else {
            failure = error is CancellationError ? nil : NexArmBluetoothFailure(step: step, error: error)
        }
        failPending(error)
        snapshot.failure = failure
        if let failure = snapshot.failure { log.error("\(String(describing: failure), privacy: .public)") }
        if keepConnection {
            // No wire request IDs: quarantine queries until reconnect rather than allowing a late reply
            // to satisfy a replacement request. Radio/notifications remain independently connected.
            queryTimeoutLatched = true
            snapshot.feedbackHealthy = false
            publish()
            return
        }
        tx = nil
        rx = nil
        if let peripheral {
            snapshot.phase = .disconnecting
            central?.cancelPeripheralConnection(peripheral)
        } else {
            snapshot.phase = .disconnected
        }
        publish()
    }
    private func disconnected(_ error: (any Error)?) {
        feedbackMonitor?.cancel()
        feedbackMonitor = nil
        feedbackWatchdog = nil
        failPending(error ?? NexArmError.disconnected)
        peripheral?.delegate = nil
        peripheral = nil
        tx = nil
        rx = nil
        snapshot.phase = .disconnected
        snapshot.selected = nil
        if let error, snapshot.failure == nil { snapshot.failure = NexArmBluetoothFailure(step: step, error: error) }
        publish()
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: snapshot.power = .poweredOn
        case .poweredOff: snapshot.power = .poweredOff
        case .unauthorized: snapshot.power = .unauthorized
        case .unsupported: snapshot.power = .unsupported
        case .resetting: snapshot.power = .resetting
        default: snapshot.power = .unknown
        }
        if central.state == .poweredOn {
            if scanRequested { beginScan() }
        } else if central.state != .unknown && central.state != .resetting {
            stopScan()
            disconnected(NexArmBluetoothError.unavailable)
        }
        publish()
    }
    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
        rssi signal: NSNumber
    ) {
        guard snapshot.scanning else { return }
        guard
            let name = NexArmBluetoothDevice.discoveryName(
                advertised: advertisementData[CBAdvertisementDataLocalNameKey] as? String, cached: peripheral.name
            )
        else { return }
        guard peripherals[peripheral.identifier] != nil || peripherals.count < 128 else {
            snapshot.discoveryLimitReached = true
            publish()
            return
        }
        peripherals[peripheral.identifier] = peripheral
        snapshot.devices.removeAll { $0.id == peripheral.identifier }
        snapshot.devices.append(
            .init(
                id: peripheral.identifier, name: name, rssi: signal.intValue
            ))
        publish()
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral, connection != nil else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        step = .services
        peripheral.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        disconnected(error ?? NexArmError.disconnected)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        disconnected(error)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral, connection != nil else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            fail(error ?? NexArmBluetoothError.incompatibleService)
            return
        }
        step = .characteristics
        peripheral.discoverCharacteristics([Self.transmit, Self.receive], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, connection != nil else { return }
        tx = service.characteristics?.first { $0.uuid == Self.transmit && $0.properties.contains(.write) }
        rx = service.characteristics?.first { $0.uuid == Self.receive && $0.properties.contains(.notify) }
        guard error == nil, tx != nil, let rx else {
            fail(error ?? NexArmBluetoothError.incompatibleService)
            return
        }
        step = .notifications
        peripheral.setNotifyValue(true, for: rx)
    }
    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard self.peripheral === peripheral, characteristic === rx else { return }
        guard error == nil, characteristic.isNotifying else {
            fail(error ?? NexArmError.disconnected)
            return
        }
        guard let connection else { return }
        self.connection = nil
        connectionID = nil
        connectionTimer?.cancel()
        connectionTimer = nil
        snapshot.phase = .connected
        queryTimeoutLatched = false
        trafficBudget = NexArmBLETrafficBudget()
        snapshot.feedbackHealthy = true
        feedbackWatchdog = NexArmFeedbackWatchdog(started: .now)
        feedbackMonitor?.cancel()
        feedbackMonitor = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.snapshot.phase == .connected else { return }
                self.updateFeedbackHealth()
                ticks += 1
                if ticks == 50 {
                    self.logTraffic()
                    ticks = 0
                }
            }
        }
        publish()
        connection.resume()
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic === tx else { return }
        if retiredWriteAcknowledgment {
            retiredWriteAcknowledgment = false
            if let error { fail(error) }
            return
        }
        guard request != nil else { return }
        if let error {
            fail(error)
            return
        }
        step = .response
        reply?.acknowledged = true
        finishReply()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic === rx else { return }
        guard error == nil, let data = characteristic.value else {
            fail(error ?? NexArmError.invalidPacket)
            return
        }
        do {
            let previousSequence = telemetry.latest?.sequence ?? 0
            let now = ContinuousClock.now
            trafficBudget.received(bytes: data.count, feedbackSamples: 0, at: now)
            try telemetry.receive(Array(data), at: now)
            let samples = (telemetry.latest?.sequence ?? 0) &- previousSequence
            trafficBudget.received(bytes: 0, feedbackSamples: samples, at: now)
            if let latest = telemetry.latest { feedbackWatchdog?.observe(at: latest.receivedAt) }
            updateFeedbackHealth()
            try reply?.receive(Array(data))
            finishReply()
        } catch { fail(error) }
    }
    private func updateFeedbackHealth() {
        guard let feedbackWatchdog, snapshot.phase == .connected else { return }
        let healthy = !queryTimeoutLatched && !feedbackWatchdog.isLost(at: .now)
        guard snapshot.feedbackHealthy != healthy else { return }
        snapshot.feedbackHealthy = healthy
        logTraffic()
        publish()
    }
    private func logTraffic() {
        let traffic = trafficBudget.diagnostics()
        log.info(
            "BLE traffic healthy=\(self.snapshot.feedbackHealthy, privacy: .public) sent=\(traffic.sentPackets, privacy: .public) bytes=\(traffic.sentBytes, privacy: .public) pacing=\(traffic.pacingDeferrals, privacy: .public) blocked=\(traffic.systemDeferrals, privacy: .public) ready=\(traffic.flowControlResumptions, privacy: .public) rxBytes=\(traffic.notificationBytes, privacy: .public) samples=\(traffic.feedbackSamples, privacy: .public) rxGapMs=\(traffic.notificationGapMilliseconds, privacy: .public) feedbackGapMs=\(traffic.feedbackGapMilliseconds, privacy: .public) maxFeedbackGapMs=\(traffic.longestFeedbackGapMilliseconds, privacy: .public)"
        )
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        trafficBudget.resumed()
    }
    private func finishReply() {
        guard let packet = reply?.completed, let request else { return }
        self.request = nil
        requestID = nil
        requestWasSent = false
        reply = nil
        requestTimer?.cancel()
        requestTimer = nil
        request.resume(returning: packet)
    }
}
