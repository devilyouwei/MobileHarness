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
                !name.isEmpty, name != "未命名设备"
            {
                return String(name.prefix(64))
            }
        }
        return nil
    }
    public static func discoveryOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        func preferred(_ name: String) -> Bool {
            name.lowercased().filter { $0.isLetter || $0.isNumber }.contains("nexarm")
        }
        if preferred(lhs.name) != preferred(rhs.name) { return preferred(lhs.name) }
        if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
        return lhs.id.uuidString < rhs.id.uuidString
    }
    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}
public struct NexArmBluetoothSnapshot: Sendable, Equatable {
    public var power: NexArmBluetoothPower = .unknown
    public var phase: NexArmBluetoothPhase = .disconnected
    public var scanning = false
    public var devices: [NexArmBluetoothDevice] = []
    public var selected: NexArmBluetoothDevice?
    public var discoveryLimitReached = false
    public var failure: String?
    public init() {}
}
public enum NexArmBluetoothError: Error, Sendable, Equatable {
    case unavailable, unknownDevice, incompatibleService, packetTooLarge
}
public protocol NexArmBluetoothLink: NexArmWritableLink {
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

/// Retain the failing native step instead of hiding every failure behind a reconnect message.
enum NexArmBluetoothStep: String {
    case connecting = "建立蓝牙连接"
    case services = "发现设备服务"
    case characteristics = "发现读写通道"
    case notifications = "开启设备通知"
    case writing = "发送设备指令"
    case response = "等待设备回复"
    func failure(_ error: any Error) -> String {
        if error as? NexArmError == .timeout { return "\(rawValue)超时" }
        if error as? NexArmBluetoothError == .incompatibleService { return "\(rawValue)失败：蓝牙服务不兼容" }
        let native = error as NSError
        return "\(rawValue)失败（\(native.domain) \(native.code)）"
    }
}

/// One request, no pending queue. ACK and a matching decoded reply are both required.
struct NexArmBLEReply {
    let id: UInt8
    let command: UInt8
    let count: Int
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
    private var telemetry = NexArmTelemetryCache()
    private var observationID: UUID?
    func beginObservation() throws -> UUID {
        guard snapshot.phase == .connected, let tx, rx?.isNotifying == true else { throw NexArmError.disconnected }
        guard liveControlID == nil, request == nil, observationID == nil else { throw NexArmError.busy }
        guard tx.properties.contains(.writeWithoutResponse) else { throw NexArmBluetoothError.incompatibleService }
        let token = UUID()
        observationID = token
        return token
    }
    func sendObserved(_ packet: NexArmPacket, session: UUID) throws -> Bool {
        try Task.checkCancellation()
        guard observationID == session, liveControlID == nil else { throw CancellationError() }
        guard snapshot.phase == .connected, let peripheral, let tx else { throw NexArmError.disconnected }
        guard packet.id == 255,
            (packet.command == 11 && packet.payload.isEmpty) || (packet.command == 8 && packet.payload.count == 14)
        else { throw NexArmError.invalidPacket }
        guard packet.bytes.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            throw NexArmBluetoothError.packetTooLarge
        }
        guard peripheral.canSendWriteWithoutResponse else { return false }
        peripheral.writeValue(Data(packet.bytes), for: tx, type: .withoutResponse)
        return true
    }
    func latestObservation(after sequence: UInt64, session: UUID) throws -> NexArmTelemetry? {
        guard observationID == session, liveControlID == nil else { throw CancellationError() }
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
    private var reply: NexArmBLEReply?
    private var requestTimer: Task<Void, Never>?
    private var liveControlID: UUID?
    private var retiredWriteAcknowledgment = false
    private var liveDrainUntil: ContinuousClock.Instant?
    private var disconnectTask: Task<Void, Never>?

    init(updates: AsyncStream<NexArmBluetoothSnapshot>.Continuation) {
        self.updates = updates
        super.init()
        publish()
    }
    private func publish() { updates.yield(snapshot) }  // Replace only presentation snapshots, never commands/results.
    private func manager() -> CBCentralManager {
        if let central { return central }
        let value = CBCentralManager(delegate: self, queue: .main)
        central = value
        return value
    }
    func status() -> NexArmBluetoothSnapshot { snapshot }
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
            snapshot.devices.first { $0.id == id } ?? .init(id: id, name: selected.name ?? "未命名设备", rssi: 0)
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
            retiredWriteAcknowledgment = !(reply?.acknowledged ?? true)
            requestTimer?.cancel()
            requestTimer = nil
            request = nil
            requestID = nil
            reply = nil
            pending.resume(throwing: CancellationError())
        }
        return token
    }
    func sendLive(_ packet: NexArmPacket, session: UUID) throws -> Bool {
        try Task.checkCancellation()
        guard liveControlID == session else { throw CancellationError() }
        guard snapshot.phase == .connected, let peripheral, let tx else { throw NexArmError.disconnected }
        guard packet.isLiveControl else { throw NexArmError.invalidPacket }
        guard packet.bytes.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            throw NexArmBluetoothError.packetTooLarge
        }
        guard peripheral.canSendWriteWithoutResponse else { return false }
        peripheral.writeValue(Data(packet.bytes), for: tx, type: .withoutResponse)
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
        guard (0...253).contains(replyCount),
            packet.bytes.count <= peripheral.maximumWriteValueLength(for: .withResponse)
        else {
            throw NexArmBluetoothError.packetTooLarge
        }
        step = .writing
        let token = UUID()
        requestID = token
        reply = NexArmBLEReply(
            id: replyID, command: replyCommand, count: replyCount,
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
                peripheral.writeValue(Data(packet.bytes), for: tx, type: .withResponse)
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
            self.snapshot.failure = "蓝牙断开尚未确认，请关闭系统蓝牙后重试"
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
        let connecting = connection
        connection = nil
        connectionID = nil
        let pending = request
        request = nil
        requestID = nil
        reply = nil
        connecting?.resume(throwing: error)
        pending?.resume(throwing: error)
    }
    private func fail(_ error: any Error) {
        failPending(error)
        snapshot.failure = error is CancellationError ? nil : step.failure(error)
        if let failure = snapshot.failure { log.error("\(failure, privacy: .public)") }
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
        failPending(error ?? NexArmError.disconnected)
        peripheral?.delegate = nil
        peripheral = nil
        tx = nil
        rx = nil
        snapshot.phase = .disconnected
        snapshot.selected = nil
        if let error, snapshot.failure == nil { snapshot.failure = step.failure(error) }
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
        snapshot.devices.sort(by: NexArmBluetoothDevice.discoveryOrder)
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
            try telemetry.receive(Array(data))
            try reply?.receive(Array(data))
            finishReply()
        } catch { fail(error) }
    }
    private func finishReply() {
        guard let packet = reply?.completed, let request else { return }
        self.request = nil
        requestID = nil
        reply = nil
        requestTimer?.cancel()
        requestTimer = nil
        request.resume(returning: packet)
    }
}
