import CoreBluetooth
import Foundation
import OSLog

/// Capability selection is native transport policy, independent of the operation's business purpose.
enum NexArmBLEWriteMode: Sendable, Equatable {
    case acknowledged, unacknowledged
    static func select(withResponse: Bool, withoutResponse: Bool, preferred: Self) throws -> Self {
        switch preferred {
        case .acknowledged:
            if withResponse { return .acknowledged }
            if withoutResponse { return .unacknowledged }
        case .unacknowledged:
            if withoutResponse { return .unacknowledged }
            if withResponse { return .acknowledged }
        }
        throw NexArmBluetoothError.incompatibleService
    }
    var nativeType: CBCharacteristicWriteType { self == .acknowledged ? .withResponse : .withoutResponse }
}

/// One GATT control acknowledgment may be outstanding. New packets remain caller-owned, never queued here.
struct NexArmBLEControlWriteWindow {
    private(set) var token: String?
    mutating func reserve() -> String? {
        guard token == nil else { return nil }
        let value = UUID().uuidString
        token = value
        return value
    }
    mutating func complete() { token = nil }
}

public enum NexArmBluetoothPower: Sendable, Equatable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}
public enum NexArmBluetoothPhase: Sendable, Equatable { case disconnected, connecting, connected, disconnecting }
public struct NexArmBluetoothDevice: Sendable, Equatable, Identifiable {
    public let id: String
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
    public init(id: String, name: String, rssi: Int) {
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
    static let minimumInterval = NexArmDeviceLimits.minimumBLEWriteInterval
    private(set) var nextWrite: ContinuousClock.Instant?
    private(set) var statistics = NexArmBluetoothTraffic()
    private var lastNotification: ContinuousClock.Instant?
    private var lastFeedback: ContinuousClock.Instant?
    private var blockedSince: ContinuousClock.Instant?

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
            blockedSince = blockedSince ?? now
            return false
        }
        blockedSince = nil
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
    mutating func cancelBlockedWrite() { blockedSince = nil }
    func isSendBlocked(at now: ContinuousClock.Instant = .now) -> Bool {
        blockedSince.map { now - $0 >= .seconds(2) } ?? false
    }
    mutating func resumed() {
        blockedSince = nil
        increment(&statistics.flowControlResumptions)
    }
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
    public var revision: UInt64 = 0
    public var connectionID = UUID().uuidString
    public var queriesQuarantined = false
    public var power: NexArmBluetoothPower = .unknown
    public var phase: NexArmBluetoothPhase = .disconnected
    public var scanning = false
    public var traffic = NexArmBluetoothTraffic()
    public var feedbackReceivedAt: ContinuousClock.Instant?
    public var feedbackPacket: NexArmPacket?
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
    func beginLiveControl() async throws -> String
    func sendLive(_ packet: NexArmPacket, session: String) async throws -> Bool
    func endLiveControl(_ session: String) async
    func clearDiscovery() async
    func forgetDevice() async throws
    func connect(_ id: String) async throws
    func disconnect() async
}

/// Actor-facing transport; CoreBluetooth objects never leave their main-actor delegate owner.
public actor NexArmBluetooth: NexArmBluetoothLink, NexArmObservableLink {
    public nonisolated let updates: AsyncStream<NexArmBluetoothSnapshot>
    private var driver: Task<NexArmBLEDriver, Never>?
    private let continuation: AsyncStream<NexArmBluetoothSnapshot>.Continuation
    private let admission: PlatformAdmission?
    private let initialSnapshot = NexArmBluetoothSnapshot()
    private func native() throws -> Task<NexArmBLEDriver, Never> {
        do {
            try admission?.check()
            if let driver { return driver }
            let continuation = continuation
            let admission = admission
            let value = Task { @MainActor in NexArmBLEDriver(updates: continuation, admission: admission) }
            driver = value
            return value
        } catch {
            admission?.report("connectivity.bluetooth", "native", error)
            throw error
        }
    }
    public init(admission: PlatformAdmission? = nil) {
        self.admission = admission
        let pair = AsyncStream<NexArmBluetoothSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = pair.stream
        continuation = pair.continuation
    }
    public func beginObservation() async throws -> String {
        do {
            return try await native().value.beginObservation()
        } catch {
            admission?.report("connectivity.bluetooth", "beginObservation", error)
            throw error
        }
    }
    public func sendObserved(_ packet: NexArmPacket, session: String) async throws -> Bool {
        do {
            return try await native().value.sendObserved(packet, session: session)
        } catch {
            admission?.report("connectivity.bluetooth", "sendObserved", error)
            throw error
        }
    }
    public func latestObservation(after sequence: UInt64, session: String) async throws -> NexArmTelemetry? {
        do {
            return try await native().value.latestObservation(after: sequence, session: session)
        } catch {
            admission?.report("connectivity.bluetooth", "latestObservation", error)
            throw error
        }
    }
    public func endObservation(_ session: String) async { await driver?.value.endObservation(session) }
    public func status() async -> NexArmBluetoothSnapshot {
        guard let driver = try? native() else { return await currentStatus() }
        return await driver.value.status()
    }
    public func currentStatus() async -> NexArmBluetoothSnapshot {
        await driver?.value.status() ?? initialSnapshot
    }
    public func scan() async throws {
        do {
            try await native().value.scan()
        } catch {
            admission?.report("connectivity.bluetooth", "scan", error)
            throw error
        }
    }
    public func stopScan() async { await driver?.value.stopScan() }
    public func beginLiveControl() async throws -> String {
        do {
            return try await native().value.beginLiveControl()
        } catch {
            admission?.report("connectivity.bluetooth", "beginLiveControl", error)
            throw error
        }
    }
    public func sendLive(_ packet: NexArmPacket, session: String) async throws -> Bool {
        do {
            return try await native().value.sendLive(packet, session: session)
        } catch {
            admission?.report("connectivity.bluetooth", "sendLive", error)
            throw error
        }
    }
    public func endLiveControl(_ session: String) async { await driver?.value.endLiveControl(session) }
    public func clearDiscovery() async { await driver?.value.clearDiscovery() }
    public func forgetDevice() async throws {
        do {
            try await native().value.forgetDevice()
        } catch {
            admission?.report("connectivity.bluetooth", "forgetDevice", error)
            throw error
        }
    }
    public func connect(_ id: String) async throws {
        do {
            try await native().value.connect(id)
        } catch {
            admission?.report("connectivity.bluetooth", "connect", error)
            throw error
        }
    }
    public func disconnect() async { await driver?.value.disconnect() }
    public func close() async { await disconnect() }
    public func write(_ packet: NexArmPacket) async throws {
        do {
            try await native().value.write(packet)
        } catch {
            admission?.report("connectivity.bluetooth", "write", error)
            throw error
        }
    }
    public func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) async throws
        -> NexArmPacket
    {
        do {
            return try await native().value.exchange(
                packet, replyID: replyID, replyCommand: replyCommand, replyCount: replyCount)
        } catch {
            admission?.report("connectivity.bluetooth", "exchange", error)
            throw error
        }
    }
}

/// Structured transport diagnostics; consumers own presentation and recovery advice.
public enum NexArmBluetoothStep: String, Sendable, Equatable {
    case connecting, services, characteristics, notifications, writing, response
}
public enum NexArmBluetoothFailure: Error, Sendable, Equatable {
    public enum ProtocolViolation: Sendable, Equatable { case invalidPacket, receiveOverflow }
    case protocolViolation(ProtocolViolation)
    case timeout(NexArmBluetoothStep)
    case responseTimeout(command: UInt8, expectedBytes: Int, receivedBytes: Int)
    case incompatibleService(NexArmBluetoothStep)
    case native(step: NexArmBluetoothStep, domain: String, code: Int)
    case disconnectUnconfirmed
    case requestInterrupted(command: UInt8)
    case sendBlocked

    public init(step: NexArmBluetoothStep, error: any Error) {
        if error as? NexArmError == .timeout {
            self = .timeout(step)
        } else if error as? NexArmError == .invalidPacket {
            self = .protocolViolation(.invalidPacket)
        } else if error as? NexArmError == .overflow {
            self = .protocolViolation(.receiveOverflow)
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
    private let admission: PlatformAdmission?
    private var trafficBudget = NexArmBLETrafficBudget()
    private var telemetry = NexArmTelemetryCache()
    private var controlWriteWindow = NexArmBLEControlWriteWindow()
    private var controlWriteTimer: Task<Void, Never>?
    private var observationID: String?
    private var feedbackWatchdog: NexArmFeedbackWatchdog?
    private var feedbackMonitor: Task<Void, Never>?
    func beginObservation() throws -> String {
        try admission?.check()
        guard snapshot.phase == .connected, let tx, rx?.isNotifying == true else { throw NexArmError.disconnected }
        guard liveControlID == nil, request == nil, observationID == nil else { throw NexArmError.busy }
        _ = try writeMode(tx, preferred: .unacknowledged)
        let token = UUID().uuidString
        observationID = token
        return token
    }
    func sendObserved(_ packet: NexArmPacket, session: String) throws -> Bool {
        try Task.checkCancellation()
        guard observationID == session, liveControlID == nil else { throw NexArmError.disconnected }
        guard snapshot.phase == .connected, let peripheral, let tx else { throw NexArmError.disconnected }
        guard packet.isObservedControl
        else { throw NexArmError.invalidPacket }
        return try writeControl(packet, peripheral: peripheral, characteristic: tx)
    }
    func latestObservation(after sequence: UInt64, session: String) throws -> NexArmTelemetry? {
        try Task.checkCancellation()
        guard observationID == session, liveControlID == nil else { throw NexArmError.disconnected }
        guard snapshot.phase == .connected else { throw NexArmError.disconnected }
        guard let latest = telemetry.latest, latest.sequence > sequence else { return nil }
        return latest
    }
    func endObservation(_ session: String) {
        if observationID == session {
            observationID = nil
            trafficBudget.cancelBlockedWrite()
        }
    }
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
    private var peripherals: [String: CBPeripheral] = [:]  // 128 discovered devices, reject excess.
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var scanRequested = false
    private var scanTimer: Task<Void, Never>?
    private var connection: CheckedContinuation<Void, any Error>?
    private var connectionID: String?
    private var connectionTimer: Task<Void, Never>?
    private var request: CheckedContinuation<NexArmPacket, any Error>?
    private var requestID: String?
    private var requestWasSent = false
    private var reply: NexArmBLEReply?
    private var requestTimer: Task<Void, Never>?
    private var requestSender: Task<Void, Never>?
    private var queryTimeoutLatched = false
    private var liveControlID: String?
    private var retiredWriteAcknowledgment = false
    private var liveDrainUntil: ContinuousClock.Instant?
    private var disconnectTask: Task<Void, Never>?

    init(updates: AsyncStream<NexArmBluetoothSnapshot>.Continuation, admission: PlatformAdmission?) {
        self.admission = admission
        self.updates = updates
        super.init()
        publish()
    }
    // Replace only presentation snapshots, never commands/results.
    private var reportedFailure: NexArmBluetoothFailure?
    private func publish() {
        if let failure = snapshot.failure, failure != reportedFailure {
            admission?.report("connectivity.bluetooth", "nativeEvent", failure)
        }
        reportedFailure = snapshot.failure
        snapshot.revision &+= 1
        snapshot.queriesQuarantined = queryTimeoutLatched
        snapshot.traffic = trafficBudget.diagnostics()
        updates.yield(snapshot)
    }
    private func manager() -> CBCentralManager {
        if let central { return central }
        let value = CBCentralManager(delegate: self, queue: .main)
        central = value
        return value
    }
    private func writeMode(_ characteristic: CBCharacteristic, preferred: NexArmBLEWriteMode) throws
        -> NexArmBLEWriteMode
    {
        try .select(
            withResponse: characteristic.properties.contains(.write),
            withoutResponse: characteristic.properties.contains(.writeWithoutResponse), preferred: preferred)
    }
    private func writeControl(_ packet: NexArmPacket, peripheral: CBPeripheral, characteristic: CBCharacteristic) throws
        -> Bool
    {
        let mode = try writeMode(characteristic, preferred: .unacknowledged)
        guard packet.bytes.count <= peripheral.maximumWriteValueLength(for: mode.nativeType) else {
            throw NexArmBluetoothError.packetTooLarge
        }
        guard controlWriteWindow.token == nil else { return false }
        if mode == .acknowledged {
            guard !retiredWriteAcknowledgment else { return false }
        }
        guard try admitWrite(peripheral, systemReady: mode == .acknowledged || peripheral.canSendWriteWithoutResponse)
        else {
            return false
        }
        if mode == .acknowledged {
            guard let token = controlWriteWindow.reserve() else { return false }
            controlWriteTimer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.controlWriteWindow.token == token else { return }
                self.fail(NexArmError.timeout, overriding: .timeout(.writing))
            }
        }
        peripheral.writeValue(Data(packet.bytes), for: characteristic, type: mode.nativeType)
        trafficBudget.sent(bytes: packet.bytes.count, at: .now)
        return true  // Native admission; physical completion still requires feedback.
    }
    private func admitWrite(_ peripheral: CBPeripheral, systemReady: Bool) throws -> Bool {
        try admission?.check()
        let accepted = trafficBudget.canSend(at: .now, systemReady: systemReady)
        if trafficBudget.isSendBlocked() {
            fail(NexArmError.timeout, overriding: .sendBlocked)
            throw NexArmError.timeout
        }
        return accepted
    }
    func status() -> NexArmBluetoothSnapshot {
        var value = snapshot
        if snapshot.phase == .connected { value.traffic = trafficBudget.diagnostics() }
        return value
    }
    func scan() throws {
        try admission?.check()
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
    func connect(_ id: String) async throws {
        try admission?.check()
        try Task.checkCancellation()
        guard snapshot.phase == .disconnected, connection == nil, disconnectTask == nil else { throw NexArmError.busy }
        let central = manager()
        guard central.state == .poweredOn else { throw NexArmBluetoothError.unavailable }
        // Retrieval is only for a device explicitly selected by the host (e.g. a remembered device).
        let remembered: CBPeripheral?
        if let nativeID = UUID(uuidString: id) {
            remembered = central.retrievePeripherals(withIdentifiers: [nativeID]).first
        } else {
            remembered = nil
        }
        guard let selected = peripherals[id] ?? remembered else {
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
        let token = UUID().uuidString
        connectionID = token
        snapshot.connectionID = token
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
    func beginLiveControl() throws -> String {
        try admission?.check()
        guard snapshot.phase == .connected, let tx else { throw NexArmError.disconnected }
        _ = try writeMode(tx, preferred: .unacknowledged)
        let token = UUID().uuidString
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
            pending.resume(throwing: NexArmError.sessionReplaced)
        }
        return token
    }
    func sendLive(_ packet: NexArmPacket, session: String) throws -> Bool {
        try Task.checkCancellation()
        return try deliverLive(packet, session: session)
    }
    private func deliverLive(_ packet: NexArmPacket, session: String) throws -> Bool {
        guard liveControlID == session else { throw NexArmError.disconnected }
        guard snapshot.phase == .connected, let peripheral, let tx else { throw NexArmError.disconnected }
        guard packet.isLiveControl else { throw NexArmError.invalidPacket }
        // Local transport admission only; no device-completion claim.
        return try writeControl(packet, peripheral: peripheral, characteristic: tx)
    }
    func endLiveControl(_ session: String) {
        if liveControlID == session {
            liveControlID = nil
            trafficBudget.cancelBlockedWrite()
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
        try packet.validateMotorWrite()
        guard liveControlID == nil, observationID == nil else { throw NexArmError.busy }
        if let liveDrainUntil, ContinuousClock.now < liveDrainUntil {
            try await Task.sleep(until: liveDrainUntil, clock: .continuous)
        }
        try Task.checkCancellation()
        guard liveControlID == nil, observationID == nil else { throw NexArmError.busy }
        guard !retiredWriteAcknowledgment else { throw NexArmError.busy }
        guard snapshot.phase == .connected, let peripheral, let tx, rx?.isNotifying == true else {
            throw NexArmError.disconnected
        }
        guard request == nil, controlWriteWindow.token == nil else { throw NexArmError.busy }
        guard !queryTimeoutLatched else { throw NexArmError.timeout }
        let mode = try writeMode(tx, preferred: .acknowledged)
        guard (0...253).contains(replyCount),
            packet.bytes.count <= peripheral.maximumWriteValueLength(for: mode.nativeType)
        else {
            throw NexArmBluetoothError.packetTooLarge
        }
        step = .writing
        let token = UUID().uuidString
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
                    // No wire transaction IDs: quarantine a read timeout or close a failed write before another request.
                    self.fail(NexArmError.timeout)
                }
                // The request slot is already reserved, so the pacing wait cannot admit a second query.
                requestSender = Task { [weak self] in
                    guard let self else { return }
                    do {
                        while true {
                            try Task.checkCancellation()
                            guard self.requestID == token, self.snapshot.phase == .connected,
                                self.peripheral === peripheral, self.liveControlID == nil, self.observationID == nil
                            else { return }
                            if try self.admitWrite(
                                peripheral, systemReady: mode == .acknowledged || peripheral.canSendWriteWithoutResponse
                            ) {
                                break
                            }
                            try await Task.sleep(for: .milliseconds(20))
                        }
                    } catch {
                        guard self.requestID == token, !(error is CancellationError) else { return }
                        self.fail(error)
                        return
                    }
                    self.requestWasSent = true
                    if mode == .unacknowledged {
                        self.reply?.acknowledged = true
                        self.step = .response
                    }
                    peripheral.writeValue(Data(packet.bytes), for: tx, type: mode.nativeType)
                    self.trafficBudget.sent(bytes: packet.bytes.count, at: .now)
                    self.requestSender = nil
                    self.finishReply()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.requestID == token else { return }
                if self.requestWasSent {
                    self.fail(CancellationError(), overriding: .requestInterrupted(command: packet.command))
                } else {
                    self.failPending(CancellationError())
                }
            }
        }
    }
    func disconnect() async {
        let workers = [scanTimer, connectionTimer, requestTimer, requestSender, controlWriteTimer, feedbackMonitor]
            .compactMap { $0 }
        for worker in workers { worker.cancel() }
        await disconnectNative()
        for worker in workers { await worker.value }
    }
    private func disconnectNative() async {
        stopScan()
        failPending(NexArmError.disconnected)
        if let disconnectTask {
            await disconnectTask.value
            return
        }
        guard let peripheral else { return }
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
        controlWriteTimer?.cancel()
        controlWriteTimer = nil
        controlWriteWindow.complete()
        trafficBudget.cancelBlockedWrite()
        observationID = nil
        telemetry = NexArmTelemetryCache()
        snapshot.feedbackPacket = nil
        snapshot.feedbackReceivedAt = nil
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
    private func fail(_ error: any Error, overriding: NexArmBluetoothFailure? = nil) {
        // Capture the pending query before failPending clears it. Never replay a timed-out request.
        let keepConnection =
            overriding == nil && error as? NexArmError == .timeout && step == .response
            && reply?.readOnlyQuery == true
        let failure: NexArmBluetoothFailure?
        if error as? NexArmError == .timeout, step == .response, let reply, !reply.acknowledgmentOnly {
            failure = .responseTimeout(
                command: reply.command, expectedBytes: reply.count, receivedBytes: reply.receivedBytes)
        } else {
            failure = error is CancellationError ? nil : NexArmBluetoothFailure(step: step, error: error)
        }
        let captured = overriding ?? failure
        failPending(error)
        snapshot.failure = captured
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
        let deviceID = peripheral.identifier.uuidString
        guard peripherals[deviceID] != nil || peripherals.count < 128 else {
            snapshot.discoveryLimitReached = true
            publish()
            return
        }
        peripherals[deviceID] = peripheral
        snapshot.devices.removeAll { $0.id == deviceID }
        snapshot.devices.append(
            .init(
                id: deviceID, name: name, rssi: signal.intValue
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
        tx = service.characteristics?.first {
            $0.uuid == Self.transmit
                && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse))
        }
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
                if self.trafficBudget.isSendBlocked() {
                    self.fail(NexArmError.timeout, overriding: .sendBlocked)
                    return
                }
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
        if controlWriteWindow.token != nil {
            controlWriteTimer?.cancel()
            controlWriteTimer = nil
            controlWriteWindow.complete()
            if let error {
                fail(
                    error,
                    overriding: NexArmBluetoothFailure(step: .writing, error: error))
            }
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
            if samples > 0 {
                snapshot.feedbackPacket = telemetry.latest?.packet
                snapshot.feedbackReceivedAt = telemetry.latest?.receivedAt
            }
            updateFeedbackHealth()
            if samples > 0 { publish() }
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

/// Device recovery bounds and native fault classification; no remembered-device or UI policy.
public struct NexArmBluetoothRecoveryPolicy {
    public static let maximumAttempts = 3
    public static let episodeTimeout: Duration = .seconds(120)
    public static func delay(attempt: Int) -> Duration { .seconds(1 << (min(maximumAttempts, max(1, attempt)) - 1)) }

    public static func canRetry(_ error: any Error, snapshot: NexArmBluetoothSnapshot) -> Bool {
        if error is CancellationError { return false }
        if let native = error as? NexArmError {
            switch native {
            case .timeout, .disconnected, .io: return true
            case .invalidPacket, .overflow:
                if case .protocolViolation = snapshot.failure { return true }
                return false
            case .busy, .sessionReplaced, .invalidMotion: return false
            }
        }
        if let bluetooth = error as? NexArmBluetoothError {
            switch bluetooth {
            case .unavailable: return snapshot.power != .unauthorized && snapshot.power != .unsupported
            case .unknownDevice, .incompatibleService, .packetTooLarge: return false
            }
        }
        // Retry an untyped system error only when the SDK recorded that same native failure.
        if case .native(_, let domain, let code) = snapshot.failure {
            let system = error as NSError
            return system.domain == domain && system.code == code
        }
        return false
    }
}

public enum NexArmBluetoothRecoveryError: Error, Sendable, Equatable {
    case episodeTimeout, disconnectUnconfirmed, notRetryable
}
