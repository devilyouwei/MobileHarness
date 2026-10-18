import Actions
import AgentBindings
import AgentCore
import Agents
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import StorageCore
import StorageMedia
import StorageSQLite
import StorageState
import StorageTasks
import Testing

@testable import ActionBindings
@testable import PlatformKit
@testable import UI

/// Explicit simulation. Default tests never create a CoreBluetooth manager or move physical hardware.
private actor BluetoothArmFixture: NexArmBluetoothLink {
    var ik = NexArmTestIK()
    private(set) var ikRequests: [NexArmPacket] = []
    private var rejectIK = false
    func rejectIKQueries() { rejectIK = true }
    private(set) var observedCommands: [NexArmPacket] = []
    var observation: String?
    var telemetry = NexArmTelemetryCache()
    var lastPush = ContinuousClock.now.advanced(by: .seconds(-1))
    var observationAdmissionError: NexArmError?
    func rejectObservation(_ error: NexArmError) { observationAdmissionError = error }
    func beginObservation() throws -> String {
        if let observationAdmissionError { throw observationAdmissionError }
        liveSession = nil
        let token = UUID().uuidString
        observation = token
        return token
    }
    private var holdObservationEnd = false
    private var pendingObservationEnd: CheckedContinuation<Void, Never>?
    var waitingForObservationEnd: Bool { pendingObservationEnd != nil }
    func blockObservationEnd() { holdObservationEnd = true }
    func releaseObservationEnd() {
        holdObservationEnd = false
        pendingObservationEnd?.resume()
        pendingObservationEnd = nil
    }
    func endObservation(_ session: String) async {
        if holdObservationEnd {
            precondition(pendingObservationEnd == nil)
            await withCheckedContinuation { pendingObservationEnd = $0 }
        }
        if observation == session { observation = nil }
    }
    func sendObserved(_ packet: NexArmPacket, session: String) throws -> Bool {
        try Task.checkCancellation()
        guard observation == session, snapshot.phase == .connected else { throw NexArmError.disconnected }
        guard try admitFixtureWrite() else { return false }
        observedCommands.append(packet)
        try write(packet)
        return true
    }
    private var observationReadError: NexArmError?
    func rejectObservationRead(_ error: NexArmError) { observationReadError = error }
    func latestObservation(after sequence: UInt64, session: String) async throws -> NexArmTelemetry? {
        try Task.checkCancellation()
        if let observationReadError { throw observationReadError }
        guard observation == session, snapshot.phase == .connected else { throw NexArmError.disconnected }
        if !telemetryUnavailable, !holdPose, ContinuousClock.now - lastPush >= .milliseconds(100) {
            let packet = try await exchange(NexArmPacket(command: 11), replyID: 255, replyCommand: 11, replyCount: 24)
            try telemetry.receive(packet.bytes)
            lastPush = .now
        }
        guard let value = telemetry.latest, value.sequence > sequence else { return nil }
        return value
    }
    func pushPosition() async throws {
        let packet = try await exchange(NexArmPacket(command: 11), replyID: 255, replyCommand: 11, replyCount: 24)
        publishFeedback(packet)
    }
    func publishFeedback(_ packet: NexArmPacket) {
        snapshot.feedbackPacket = packet
        snapshot.feedbackReceivedAt = .now
        snapshot.feedbackHealthy = true
        emit.yield(snapshot)
    }
    func health(_ healthy: Bool) {
        snapshot.feedbackHealthy = healthy
        emit.yield(snapshot)
    }
    nonisolated let updates: AsyncStream<NexArmBluetoothSnapshot>
    private let emit: AsyncStream<NexArmBluetoothSnapshot>.Continuation
    nonisolated let id = UUID().uuidString
    nonisolated let records = Result { try SQLiteRepositories.temporary() }
    nonisolated var businessID: String {
        get throws { "device_1" }
    }
    var snapshot = NexArmBluetoothSnapshot()
    var dropPositionReplies = false
    func dropPositions() { dropPositionReplies = true }
    var failNextPosition = false
    var failedConnectionsRemaining = 0
    var disconnectUnconfirmed = false
    func failConnections(_ count: Int) { failedConnectionsRemaining = count }
    func failPositionOnce() { failNextPosition = true }
    func refuseDisconnect(_ value: Bool) { disconnectUnconfirmed = value }
    func power(_ value: NexArmBluetoothPower) {
        snapshot.power = value
        if value != .poweredOn { snapshot.phase = .disconnected }
        emit.yield(snapshot)
    }
    func lateSnapshot(_ value: NexArmBluetoothSnapshot) { emit.yield(value) }
    func setRevision(_ value: UInt64) {
        snapshot.revision = value
        emit.yield(snapshot)
    }
    var missingVersion = false
    var reportedVersion: [UInt8]?
    var driftingPose = false
    private(set) var connects = 0
    private(set) var versionReads = 0
    var wrongVersion = false
    var incompatibleService = false
    var displayName = "Nex_Arm"
    var holdConnection = false
    var roll = 0
    var failMotion = false
    var failFeedback = false
    var loseLinkOnMotion = false
    var loseLinkOnFeedback = false
    var x = 270
    var y = 0
    var resetHeight = 197
    var z = 350
    var pitch = -180
    var claw = -35
    var liveSession: String?
    var failNextLiveValidation = false
    func failLiveValidationOnce() { failNextLiveValidation = true }
    var liveBlocked = false
    var blockedSince: ContinuousClock.Instant?
    func admitFixtureWrite() throws -> Bool {
        if !liveBlocked {
            blockedSince = nil
            return true
        }
        blockedSince = blockedSince ?? .now
        if ContinuousClock.now - blockedSince! >= .seconds(2) {
            snapshot.failure = .sendBlocked
            snapshot.phase = .disconnected
            emit.yield(snapshot)
            throw NexArmError.timeout
        }
        return false
    }
    var limitLiveRate = false
    var lastLiveWrite: ContinuousClock.Instant?
    func throttleLive() { limitLiveRate = true }
    var telemetryUnavailable = false
    var holdPose = false
    var pendingPose: CheckedContinuation<Void, any Error>?
    func holdTelemetry() { holdPose = true }
    func resumeTelemetry() {
        holdPose = false
        telemetryUnavailable = false
    }
    var waitingForPose: Bool { pendingPose != nil }
    private(set) var liveCommands: [NexArmPacket] = []
    private(set) var poseReads = 0
    func blockLive(_ value: Bool) {
        liveBlocked = value
        if !value { blockedSince = nil }
    }
    func disableTelemetry() { telemetryUnavailable = true }
    func beginLiveControl() throws -> String {
        guard snapshot.phase == .connected else { throw NexArmError.disconnected }
        observation = nil
        let id = UUID().uuidString
        liveSession = id
        pendingPose?.resume(throwing: NexArmError.sessionReplaced)
        pendingPose = nil
        return id
    }
    private var failLiveAfterDisconnect = false
    private var pendingLiveFailure: CheckedContinuation<Void, Never>?
    var waitingForLiveFailure: Bool { pendingLiveFailure != nil }
    func failLiveAfterNativeDisconnect() { failLiveAfterDisconnect = true }
    func releaseLiveFailure() {
        pendingLiveFailure?.resume()
        pendingLiveFailure = nil
    }
    func sendLive(_ packet: NexArmPacket, session: String) async throws -> Bool {
        guard liveSession == session, snapshot.phase == .connected else { throw NexArmError.disconnected }
        if failNextLiveValidation {
            failNextLiveValidation = false
            throw NexArmError.invalidMotion
        }
        if failLiveAfterDisconnect {
            failLiveAfterDisconnect = false
            snapshot.phase = .disconnected
            snapshot.failure = .timeout(.writing)
            emit.yield(snapshot)
            await withCheckedContinuation { pendingLiveFailure = $0 }
            throw NexArmError.timeout
        }
        guard try admitFixtureWrite() else { return false }
        if limitLiveRate, let lastLiveWrite, ContinuousClock.now - lastLiveWrite < .milliseconds(50) { return false }
        lastLiveWrite = .now
        liveCommands.append(packet)
        // Unacknowledged command admission is recorded separately; no fake feedback completion.
        if let targets = packet.motorTargets {
            for (id, target) in targets {
                if id == 5 { wrist = target } else { motorOverrides[id - 1] = target }
            }
        }
        return true
    }
    var holdLiveEnd = false
    var pendingLiveEnd: CheckedContinuation<Void, Never>?
    var waitingForLiveEnd: Bool { pendingLiveEnd != nil }
    func blockLiveEnd() { holdLiveEnd = true }
    func releaseLiveEnd() {
        holdLiveEnd = false
        pendingLiveEnd?.resume()
        pendingLiveEnd = nil
    }
    func endLiveControl(_ session: String) async {
        if holdLiveEnd { await withCheckedContinuation { pendingLiveEnd = $0 } }
        if liveSession == session { liveSession = nil }
    }
    var motorOverrides: [Int: Int] = [:]
    var wrist = 2048
    private(set) var feedbackCommands: [NexArmPacket] = []
    private(set) var writes = 0
    private(set) var disconnects = 0
    init() {
        let pair = AsyncStream<NexArmBluetoothSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = pair.stream
        emit = pair.continuation
    }
    func configure(
        wrong: Bool = false, hold: Bool = false, fail: Bool = false, missing: Bool = false,
        feedbackFailure: Bool = false
    ) {
        missingVersion = missing
        wrongVersion = wrong
        incompatibleService = wrong
        holdConnection = hold
        failMotion = fail
        failFeedback = feedbackFailure
    }
    func simulateDiscovery(_ devices: [NexArmBluetoothDevice]) {
        snapshot.devices = devices
        emit.yield(snapshot)
    }
    func loseConnectionOnNextFeedback() { loseLinkOnFeedback = true }
    func loseConnectionOnNextMotion() { loseLinkOnMotion = true }
    func nativeWriteFailure() throws {
        snapshot.failure = .timeout(.writing)
        snapshot.phase = .disconnected
        emit.yield(snapshot)
        throw NexArmError.timeout
    }
    func loseConnection() {
        snapshot.phase = .disconnected
        snapshot.failure = .timeout(.response)
        emit.yield(snapshot)
    }
    func invalidatePose() { z = 0 }
    func setResetHeight(_ height: Int) { resetHeight = height }
    func setVersion(_ bytes: [UInt8]) { reportedVersion = bytes }
    func setDriftingPose() { driftingPose = true }
    func rename(_ value: String) { displayName = value }
    func status() -> NexArmBluetoothSnapshot { snapshot }
    func scan() {
        snapshot.power = .poweredOn
        snapshot.scanning = true
        snapshot.devices = [.init(id: id, name: displayName, rssi: -45)]
        emit.yield(snapshot)
    }
    func stopScan() {
        snapshot.scanning = false
        emit.yield(snapshot)
    }
    func clearDiscovery() {
        stopScan()
        snapshot.devices = []
        snapshot.discoveryLimitReached = false
        emit.yield(snapshot)
    }
    func forgetDevice() throws {
        guard snapshot.phase == .disconnected else { throw NexArmError.busy }
        clearDiscovery()
        snapshot.selected = nil
        snapshot.failure = nil
        emit.yield(snapshot)
    }
    func connect(_ id: String) async throws {
        guard id == self.id else { throw NexArmBluetoothError.unknownDevice }
        connects += 1
        snapshot.connectionID = UUID().uuidString
        snapshot.selected = .init(id: id, name: displayName, rssi: -45)
        if failedConnectionsRemaining > 0 {
            failedConnectionsRemaining -= 1
            emit.yield(snapshot)
            throw NexArmError.timeout
        }
        snapshot.selected = .init(id: id, name: displayName, rssi: -45)
        snapshot.failure = nil
        snapshot.phase = .connecting
        emit.yield(snapshot)
        if holdConnection { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        if incompatibleService { throw NexArmBluetoothError.incompatibleService }
        snapshot.phase = .connected
        snapshot.feedbackHealthy = true
        snapshot.queriesQuarantined = false
        telemetry = NexArmTelemetryCache()
        liveSession = nil
        observation = nil
        emit.yield(snapshot)
    }
    func disconnect() {
        disconnects += 1
        pendingPose?.resume(throwing: NexArmError.disconnected)
        pendingPose = nil
        liveSession = nil
        observation = nil
        snapshot.phase = disconnectUnconfirmed ? .disconnecting : .disconnected
        if disconnectUnconfirmed { snapshot.failure = .disconnectUnconfirmed }
        snapshot.scanning = false
        emit.yield(snapshot)
    }
    func close() { disconnect() }
    func write(_ packet: NexArmPacket) throws {
        guard liveSession == nil else { throw NexArmError.busy }
        guard snapshot.phase == .connected else { throw NexArmError.disconnected }
        if packet.command == 3, let targets = packet.motorTargets {
            let indicating = observation == nil  // Explicit legacy indication helper only; connection is passive.
            if indicating { feedbackCommands.append(packet) } else { writes += 1 }
            if (indicating && loseLinkOnFeedback) || (!indicating && loseLinkOnMotion) {
                loseLinkOnFeedback = false
                loseLinkOnMotion = false
                loseConnection()
                throw NexArmError.timeout
            }
            if failMotion || failFeedback { try nativeWriteFailure() }
            for (id, target) in targets {
                if id == 5 { wrist = target } else { motorOverrides[id - 1] = target }
            }
            return
        }
        if packet.isSynchronousPositionWrite {
            writes += 1
            if loseLinkOnMotion || loseLinkOnFeedback {
                loseLinkOnMotion = false
                loseLinkOnFeedback = false
                loseConnection()
                throw NexArmError.timeout
            }
            if failMotion || failFeedback { try nativeWriteFailure() }
            if let intent = try? ik.intent(packet) {
                let values = stride(from: 0, to: 12, by: 2).map {
                    Int(Int16(bitPattern: UInt16(intent.payload[$0]) | UInt16(intent.payload[$0 + 1]) << 8))
                }
                x = values[1]
                y = values[2]
                z = values[3]
                pitch = values[0]
                roll = values[4]
            }
            for (motor, target) in packet.motorTargets ?? [:] {
                if motor == 5 { wrist = target } else { motorOverrides[motor - 1] = target }
            }
            return
        }
        feedbackCommands.append(packet)
        if loseLinkOnFeedback {
            loseLinkOnFeedback = false
            loseConnection()
            throw NexArmError.timeout
        }
        if failFeedback { try nativeWriteFailure() }
        if packet.command == 54 {
            x = 200
            y = 0
            z = resetHeight
            pitch = -12
            claw = 0
            wrist = 2048
            motorOverrides = [:]
        } else if packet.command == 51 {
            guard packet.payload.count == 5, (1...6).contains(packet.payload[0]) else {
                throw NexArmError.invalidPacket
            }
            let target = Int(packet.payload[1]) | Int(packet.payload[2]) << 8
            if packet.payload[0] == 5 { wrist = target } else { motorOverrides[Int(packet.payload[0]) - 1] = target }
        } else {
            throw NexArmError.invalidPacket
        }
    }
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) async throws
        -> NexArmPacket
    {
        guard liveSession == nil else { throw NexArmError.busy }
        guard snapshot.phase == .connected else { throw NexArmError.disconnected }
        if packet.command == 11, dropPositionReplies || failNextPosition {
            failNextPosition = false
            snapshot.feedbackHealthy = false
            snapshot.queriesQuarantined = true
            snapshot.failure = .responseTimeout(command: 11, expectedBytes: 24, receivedBytes: 0)
            emit.yield(snapshot)
            throw NexArmError.timeout
        }
        if packet.command == 7 {
            ikRequests.append(packet)
            if rejectIK {
                snapshot.failure = .responseTimeout(command: 7, expectedBytes: 24, receivedBytes: 0)
                snapshot.queriesQuarantined = true
                emit.yield(snapshot)
                throw NexArmError.timeout
            }
            return try ik.reply(packet)
        }
        if packet.command == 1 {
            versionReads += 1
            if let reportedVersion { return try NexArmPacket(command: 1, payload: reportedVersion) }
            if missingVersion { return try NexArmPacket(command: 1, payload: [1, 0, 2, 0, 0, 0]) }
            return try NexArmPacket(command: 1, payload: wrongVersion ? [9, 0, 0, 9, 0, 0] : [1, 0, 2, 1, 0, 2])
        }
        if packet.command == 11 {
            poseReads += 1
            if telemetryUnavailable { throw NexArmError.timeout }
            if holdPose { try await withCheckedThrowingContinuation { pendingPose = $0 } }
        }
        if packet.command == 0x32 {
            guard liveSession == nil else { throw NexArmError.busy }
            writes += 1
            if loseLinkOnMotion {
                loseLinkOnMotion = false
                loseConnection()
                throw NexArmError.timeout
            }
            if failMotion { try nativeWriteFailure() }
            let p = packet.payload
            #expect(Array(p[4..<12]) == Array(repeating: 0, count: 8))
            x += Int(Int16(bitPattern: UInt16(p[0]) | UInt16(p[1]) << 8))
            y += Int(Int16(bitPattern: UInt16(p[2]) | UInt16(p[3]) << 8))
        }
        if driftingPose { wrist += 10 }
        let base = 2048 - Int((atan2(Double(y), Double(x)) * 4096 / (2 * .pi)).rounded())
        var motors = [base, 2048, 2048, 2048, wrist, 1647]
        for (index, value) in motorOverrides { motors[index] = value }
        let values = [x, y, z, pitch, roll, claw] + motors
        return try NexArmPacket(
            command: 11,
            payload: values.flatMap {
                let bits = UInt16(bitPattern: Int16($0))
                return [UInt8(bits & 255), UInt8(bits >> 8)]
            })
    }
}

@MainActor
private func bluetoothTestWorkflow(_ link: BluetoothArmFixture, file: URL) -> BluetoothWorkflow {
    BluetoothWorkflow(
        state: BluetoothSettingsState(), link: link,
        makeDeviceRepository: { try SQLiteRepositories(url: file).devices })
}
@MainActor
private func until(attempts: Int = 1500, context: String = "", _ predicate: @MainActor () async -> Bool) async throws {
    for _ in 0..<attempts {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for a controlled test event: \(context)")
    throw NexArmError.timeout
}
private func bluetoothTestFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "bluetooth-tests-\(UUID().uuidString).json")
}

@Test(.actionCatalog) func bluetoothReplyRequiresACKAndMatchingReassembledPacket() throws {
    var reply = NexArmBLEReply(id: 255, command: 1, count: 6)
    let packet = try NexArmPacket(command: 1, payload: [1, 0, 2, 1, 0, 2])
    try reply.receive(try NexArmPacket(command: 11, payload: [1, 2]).bytes)
    try reply.receive(Array(packet.bytes.prefix(4)))
    #expect(reply.completed == nil)
    try reply.receive(Array(packet.bytes.dropFirst(4)))
    #expect(reply.completed == nil)
    reply.acknowledged = true
    #expect(reply.completed == packet)
    var wrong = NexArmBLEReply(id: 255, command: 1, count: 6, acknowledged: true)
    try wrong.receive(try NexArmPacket(id: 1, command: 1, payload: packet.payload).bytes)
    #expect(wrong.completed == nil)
    #expect(throws: NexArmError.overflow) { try wrong.receive(Array(repeating: 0, count: 16_385)) }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothSettingsConnectionPersistsAcrossNavigationAndAssistantExecutes() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .connected)
    #expect(workflow.state.remembered?.id == (try link.businessID))
    let connectedRecord = try SQLiteRepositories(url: file).devices.selectedDevice()
    #expect(connectedRecord?.reconnect == true)
    #expect(await link.feedbackCommands.isEmpty)
    #expect(await link.observedCommands.isEmpty)
    workflow.openPage()
    await workflow.waitUntilIdle()
    #expect(await link.feedbackCommands.isEmpty)
    workflow.closePage()
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .connected)
    #expect(await link.disconnects == 0)
    try await runNexArmAssistantAction(cycles: 1) { try await workflow.shakeBase(cycles: $0) }
    #expect(await link.writes == 5)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .idle)
    #expect(workflow.state.remembered?.id == (try link.businessID))
    await #expect(throws: NexArmExecutionError.self) { try await workflow.shakeBase(cycles: 1) }
    observer.cancel()
    await observer.value
    let restored = bluetoothTestWorkflow(BluetoothArmFixture(), file: file)
    let restoreObserver = Task { await restored.run() }
    let rememberedID = try link.businessID
    try await until { restored.state.remembered?.id == rememberedID }
    restored.forget()
    await restored.waitUntilIdle()
    #expect(restored.state.remembered == nil)
    let saved = try SQLiteRepositories(url: file).devices.selectedDevice()
    #expect(saved?.id == nil)
    restoreObserver.cancel()
    await restoreObserver.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothRejectsIncompatibleServiceAndCancelsConnectingOnBackground() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await link.configure(wrong: true)
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .failed)
    #expect(workflow.state.remembered == nil)
    await #expect(throws: NexArmExecutionError.self) { try await workflow.shakeBase(cycles: 1) }
    #expect(await link.writes == 0)
    await link.configure(hold: true)
    workflow.connect(try link.businessID)
    try await until { await link.status().phase == .connecting }
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .idle)
    await #expect(throws: NexArmExecutionError.self) { try await workflow.shakeBase(cycles: 1) }
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothBackgroundJoinsCommittedLegAndDoesNotResumeMotion() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let movement = Task { try await workflow.shakeBase(cycles: 3) }
    try await until { await link.writes == 1 }
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    await #expect(throws: CancellationError.self) { try await movement.value }
    #expect(await link.writes == 1)
    #expect(workflow.state.phase == .connected)
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(await link.writes == 1)
    #expect(workflow.state.phase == .connected)
    #expect(await link.feedbackCommands.isEmpty)
    #expect(await link.connects == 1)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothFailedWriteRecoversConnectionWithoutReplayingTheGesture() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.configure(fail: true)
    await #expect(throws: NexArmError.timeout) { try await workflow.shakeBase(cycles: 1) }
    #expect(!workflow.state.controlReady)
    #expect(await link.writes == 1)
    await link.configure()
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady && workflow.state.error == nil)
    #expect(await link.writes == 1)
    try await workflow.shakeBase(cycles: 1)
    #expect(await link.writes == 6)
    #expect(await link.connects == 2)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) func bluetoothFailureIdentifiesNativeStep() {
    #expect(BluetoothPresentation.failure(.timeout(.connecting)) == "建立蓝牙连接超时")
    #expect(BluetoothPresentation.failure(.timeout(.notifications)) == "开启设备通知超时")
    #expect(BluetoothPresentation.failure(.timeout(.response)) == "等待设备回复超时")
    let native = NexArmBluetoothFailure(step: .writing, error: NSError(domain: "fixture.transport", code: 42))
    #expect(native == .native(step: .writing, domain: "fixture.transport", code: 42))
    #expect(BluetoothPresentation.failure(native) == "发送设备指令失败（fixture.transport 42）")
    #expect(BluetoothPresentation.failure(.incompatibleService(.services)) == "发现设备服务失败：蓝牙服务不兼容")
    #expect(BluetoothPresentation.failure(.disconnectUnconfirmed) == "蓝牙断开尚未确认，请关闭系统蓝牙后重试")
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothPoseProtocolConnectsWithoutFirmwareQueriesAndAssistantExecutes() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.configure(missing: true)
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady)
    #expect(workflow.state.error == nil)
    #expect(await link.versionReads == 0)
    #expect(await link.feedbackCommands.isEmpty)
    #expect(await link.writes == 0)
    workflow.openPage()
    workflow.closePage()
    await workflow.waitUntilIdle()
    #expect(await link.feedbackCommands.isEmpty)
    try await runNexArmAssistantAction(cycles: 1) { try await workflow.shakeBase(cycles: $0) }
    #expect(await link.writes == 5)
    #expect(await link.versionReads == 0)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    #expect(!workflow.state.controlReady)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothPassiveConnectionDoesNotValidateBusinessPose() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.configure(missing: true)
    await link.invalidatePose()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady)
    #expect(await link.feedbackCommands.isEmpty)
    #expect(await link.writes == 0)
    #expect(workflow.state.error == nil)
    #expect(await link.poseReads == 0)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothBackgroundCancelsPendingConnectionWithoutSendingAnIndication() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await link.configure(hold: true)
    workflow.connect(try link.businessID)
    try await until { await link.status().phase == .connecting }
    #expect(workflow.state.phase == .connecting && !workflow.state.controlReady)
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    #expect(await link.feedbackCommands.isEmpty)
    #expect(workflow.state.phase == .idle && !workflow.state.controlReady)
    #expect(await link.status().phase == .disconnected)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) func bluetoothWriteAcknowledgmentDoesNotMasqueradeAsPositionFeedback() throws {
    let outgoing = try NexArmPacket(command: 54, payload: [0xD0, 0x07])
    var reply = NexArmBLEReply(id: 255, command: 54, count: 0, acknowledgmentOnly: true, response: outgoing)
    try reply.receive(try NexArmPacket(command: 11, payload: Array(repeating: 0, count: 24)).bytes)
    #expect(reply.completed == nil)
    reply.acknowledged = true
    #expect(reply.completed == outgoing)  // Private ACK token, not public position data.
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothConnectionFeedbackFailureKeepsLinkAndDoesNotReplayGesture() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.configure(feedbackFailure: true)
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .connected && workflow.state.controlReady)
    workflow.openPage()
    await workflow.waitUntilIdle()
    #expect(await link.feedbackCommands.isEmpty)
    await link.configure()
    try await link.pushPosition()
    try await until { workflow.state.joints.count == 6 }
    await workflow.refreshDevice()
    #expect(await link.feedbackCommands.isEmpty)
    #expect(await link.writes == 0)
    #expect(await link.connects == 1)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) func nexArmStrictFirmwareAndBLEPosePoliciesRejectInvalidInputs() async throws {
    for version: [UInt8] in [[1, 0, 2, 1, 0, 3], [1, 0, 3, 0, 0, 0], [0, 0, 0, 0, 0, 0]] {
        let link = BluetoothArmFixture()
        await link.setVersion(version)
        try await link.connect(link.id)
        let controller = NexArmActionController(link: link)
        await #expect(throws: NexArmExecutionError.unsupportedFirmware) { try await controller.verifyCompatibility() }
        #expect(await link.versionReads == 1)
        #expect(await link.feedbackCommands.isEmpty)
        await link.close()
    }
    let moving = BluetoothArmFixture()
    await moving.configure(missing: true)
    await moving.setDriftingPose()
    try await moving.connect(moving.id)
    let controller = NexArmActionController(link: moving, compatibilityPolicy: .nexArmBLEProtocol)
    await #expect(throws: NexArmActionError.moving) { try await controller.verifyCompatibility() }
    #expect(await moving.feedbackCommands.isEmpty)
    await moving.close()
}

@Test(.actionCatalog) func bluetoothDiscoveryPrioritizesNamesButKeepsRenamedAndOtherDevices() {
    let renamed = NexArmBluetoothDevice(id: UUID().uuidString, name: "桌上的手臂", rssi: -20)
    let other = NexArmBluetoothDevice(id: UUID().uuidString, name: "温度计", rssi: -30)
    let arm = NexArmBluetoothDevice(id: UUID().uuidString, name: "Nex_Arm", rssi: -80)
    let unnamed = NexArmBluetoothDevice(id: UUID().uuidString, name: "未命名设备", rssi: -60)
    let rows = [renamed, other, arm, unnamed].sorted(by: BluetoothPresentation.discoveryOrder)
    #expect(rows.map(\.id) == [arm.id, renamed.id, other.id, unnamed.id])
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothRenamedDeviceResumesWithoutSettingsOrMovementAndManualDisconnectPersists() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.rename("桌上的手臂")
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    workflow.closePage()
    #expect(workflow.state.controlReady)
    #expect(await link.versionReads == 0)
    let commands = await link.feedbackCommands
    workflow.setForeground(false)
    // Return before control cleanup completes; reuse waits for the existing owner to retire.
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady)
    #expect(await link.connects == 1)
    #expect(await link.feedbackCommands == commands)
    #expect(await link.writes == 0)
    #expect(workflow.state.recoveryAttempt == 0)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    workflow.setForeground(false)
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(await link.connects == 1)
    #expect(!workflow.state.controlReady)
    let saved = try SQLiteRepositories(url: file).devices.selectedDevice()
    #expect(saved?.reconnect == false)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothColdStartRestoresPreviouslyVerifiedDeviceWithoutGesture() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let store = try SQLiteRepositories(url: file)
    let selected = try store.devices.device(nativeID: link.id, name: "已改名机械臂")
    try store.devices.selectDevice(selected, reconnect: true)
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    try await until { workflow.state.controlReady }
    #expect(await link.connects == 1)
    #expect(await link.feedbackCommands.isEmpty)
    #expect(await link.versionReads == 0)
    workflow.forget()
    await workflow.waitUntilIdle()
    workflow.setForeground(false)
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(await link.connects == 1)
    #expect(workflow.state.remembered == nil)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothManualDisconnectDuringBackgroundCleanupDisablesPersistedRecovery() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let movement = Task { try await workflow.shakeBase(cycles: 2) }
    try await until { await link.writes == 1 }
    workflow.setForeground(false)
    workflow.disconnect()
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    await #expect(throws: CancellationError.self) { try await movement.value }
    #expect(await link.connects == 1)
    #expect(await link.writes == 1)
    let saved = try SQLiteRepositories(url: file).devices.selectedDevice()
    #expect(saved?.reconnect == false)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothGestureBackgroundCancelsRemainingLegsAndNeverReplays() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let movement = Task { try await workflow.performGesture(.wave, repetitions: 3) }
    try await until { await link.writes >= 1 }
    await #expect(throws: NexArmExecutionError.busy) {
        try await workflow.performGesture(.celebrate, repetitions: 1)
    }
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    await #expect(throws: CancellationError.self) { try await movement.value }
    #expect(await link.feedbackCommands.isEmpty)
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady)
    #expect(await link.feedbackCommands.isEmpty)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) func bluetoothJogPlannerUsesSpeedCurveAndVendorJointLimits() throws {
    for id in 1...6 {
        var planner = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
        #expect(try planner.proposal(id: id, deflection: 0) == nil)
        for _ in 0..<200 {
            if let proposal = try planner.proposal(id: id, deflection: 1) {
                planner.accept(proposal)
            }
        }
        #expect(Int(planner.targets[id - 1]) == NexArmJogPlanner.limits[id - 1].upperBound)
        #expect(planner.targets[id - 1] - Double(NexArmGesture.referenceHomeJoints[id - 1]) > 91)
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothAllSixJoysticksStreamWithoutTelemetryAndReleaseDoesNotReset() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let reads = await link.poseReads
    await link.disableTelemetry()
    await link.throttleLive()
    for id in 1...6 { workflow.setMotorVelocity(id: id, value: 1) }
    try await until { await link.liveCommands.count >= 24 }
    workflow.stopMotorControl()
    await workflow.waitUntilIdle()
    let commands = await link.liveCommands
    #expect(Set(commands.map { $0.id }) == Set(UInt8(1)...UInt8(6)))
    #expect(commands.allSatisfy { $0.command == 3 && $0.isLiveControl })
    #expect(await link.poseReads == reads)
    #expect(!workflow.state.jogging && workflow.state.controlReady)
    let count = commands.count
    try await Task.sleep(for: .milliseconds(150))
    #expect(await link.liveCommands.count == count)
    workflow.setMotorVelocity(id: 1, value: -0.5)
    try await until { await link.liveCommands.count > count }
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    #expect(!workflow.state.jogging)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothLiveBackpressureDoesNotAccumulateCommandsAndResetPreemptsPreset() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let initial = NexArmGesture.referenceHomeJoints[1]
    await link.blockLive(true)
    workflow.setMotorVelocity(id: 2, value: 1)
    try await Task.sleep(for: .milliseconds(180))
    #expect(await link.liveCommands.isEmpty)
    workflow.setMotorVelocity(id: 2, value: -1)
    await link.blockLive(false)
    try await until { await link.liveCommands.count >= 5 }
    workflow.stopMotorControl()
    await workflow.waitUntilIdle()
    let sent = await link.liveCommands
    let last = try #require(sent.last)
    #expect(Int(last.payload[2]) | Int(last.payload[3]) << 8 < initial)
    #expect(sent.allSatisfy { Int($0.payload[2]) | Int($0.payload[3]) << 8 <= initial + 2 })
    let action = Task { try await workflow.performGesture(.wave, repetitions: 3) }
    try await until { await link.writes >= 1 }
    let before = ContinuousClock.now
    workflow.tryAction(.reset)
    try await until { await link.observedCommands.contains { $0.isSynchronousPositionWrite } }
    #expect(ContinuousClock.now - before < .seconds(1))
    await workflow.waitUntilIdle()
    await #expect(throws: CancellationError.self) { try await action.value }
    #expect(await link.observedCommands.contains { $0.isSynchronousPositionWrite })
    #expect(workflow.state.error == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func bluetoothControllerPropagatesNativeFailureWithoutReplaying() async throws {
    let link = BluetoothArmFixture()
    try await link.connect(link.id)
    await link.configure(feedbackFailure: true)
    let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
    await #expect(throws: NexArmError.timeout) {
        try await controller.performGesture(.wave, repetitions: 1)
    }
    await #expect(throws: NexArmError.disconnected) { try await controller.resetPosition() }
    #expect(await link.observedCommands.count == 1)
    await link.close()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothJoysticksAcceptOnlyNewInputAfterFailedWriteRecovery() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.configure(feedbackFailure: true)
    await #expect(throws: NexArmError.timeout) {
        try await workflow.performGesture(.wave, repetitions: 1)
    }
    await link.configure()
    await workflow.waitUntilIdle()
    await link.disableTelemetry()
    let reads = await link.poseReads
    workflow.setMotorVelocity(id: 3, value: 0.75)
    try await until { await link.liveCommands.count >= 3 }
    workflow.stopMotorControl()
    await workflow.waitUntilIdle()
    #expect(await link.poseReads == reads)
    #expect(workflow.state.controlReady && workflow.state.error == nil)
    #expect(await link.connects == 2)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func bluetoothRecoveryRequiresStationaryFeedbackAndSendsNoCommands() async throws {
    let link = BluetoothArmFixture()
    try await link.connect(link.id)
    let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
    await link.configure(feedbackFailure: true)
    await #expect(throws: NexArmError.timeout) {
        try await controller.performGesture(.wave, repetitions: 1)
    }
    let beforeRecovery = await link.writes
    await link.configure()
    try await link.connect(link.id)
    await link.setDriftingPose()
    await #expect(throws: NexArmActionError.moving) { try await controller.recoverState() }
    #expect(await link.writes == beforeRecovery)
    // A fresh target hit succeeds even if later feedback would continue drifting.
    try await controller.performGesture(.wave, repetitions: 1)
    #expect(await controller.motorResults.allSatisfy { $0.failure == nil })
    let attempted = await link.writes
    #expect(attempted > 1)
    await link.close()
    await #expect(throws: NexArmError.disconnected) { try await controller.recoverState() }
    #expect(await link.writes == attempted)
}

@Test(.actionCatalog) func bluetoothDiscoverySeparatesDeviceNamesFromPresentationPolicy() {
    #expect(BluetoothPresentation.deviceName("未命名设备") == nil)
    #expect(NexArmBluetoothDevice.discoveryName(advertised: nil, cached: nil) == nil)
    #expect(NexArmBluetoothDevice.discoveryName(advertised: "  \n", cached: "未命名设备") == "未命名设备")
    #expect(NexArmBluetoothDevice.discoveryName(advertised: "", cached: " NexArm ") == "NexArm")
    #expect(NexArmBluetoothDevice.discoveryName(advertised: "桌上的机械臂", cached: "旧名字") == "桌上的机械臂")
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothConnectAndForgetClearDiscoveryAndSavedState() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    let rows: [NexArmBluetoothDevice] = [
        .init(id: link.id, name: "NexArm", rssi: -40),
        .init(id: UUID().uuidString, name: "未命名设备", rssi: -20),
        .init(id: UUID().uuidString, name: " ", rssi: -20),
        .init(id: UUID().uuidString, name: "温度计", rssi: -20),
    ]
    await link.simulateDiscovery(rows)
    try await until { workflow.state.nearby.count == 2 }
    workflow.connect(try link.businessID)
    #expect(workflow.state.nearby.isEmpty && !workflow.state.scanning)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady)
    let connected = await link.status()
    #expect(!connected.scanning && connected.devices.isEmpty)
    workflow.state.present(.error("旧错误"))
    workflow.forget()
    await workflow.waitUntilIdle()
    #expect(workflow.state.remembered == nil && workflow.state.selected == nil)
    #expect(workflow.state.error == nil)
    #expect(workflow.state.nearby.isEmpty && workflow.state.joints.isEmpty)
    let forgotten = await link.status()
    #expect(forgotten.selected == nil && forgotten.failure == nil && forgotten.devices.isEmpty)
    // Late snapshots from the old scan cannot resurrect a forgotten row.
    await link.simulateDiscovery(rows)
    try await Task.sleep(for: .milliseconds(30))
    #expect(workflow.state.nearby.isEmpty)
    workflow.setForeground(false)
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(await link.connects == 1)
    observer.cancel()
    await observer.value
    let replacement = BluetoothArmFixture()
    let relaunched = bluetoothTestWorkflow(replacement, file: file)
    let relaunchObserver = Task { await relaunched.run() }
    await relaunched.waitUntilIdle()
    #expect(relaunched.state.remembered == nil)
    #expect(await replacement.connects == 0)
    relaunchObserver.cancel()
    await relaunchObserver.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothTransportLossRecoversOnceWithoutMotionReplay() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.loseConnectionOnNextMotion()
    await #expect(throws: (any Error).self) { try await workflow.shakeBase(cycles: 3) }
    try await until { await link.connects == 2 && workflow.state.controlReady }
    await workflow.waitUntilIdle()
    #expect(await link.writes == 1)
    #expect(await link.feedbackCommands.isEmpty)
    #expect(workflow.state.error == nil)
    #expect(workflow.state.nearby.isEmpty && !workflow.state.scanning)
    // One failed automatic connection does not start an endless retry loop.
    await link.configure(wrong: true)
    await link.loseConnection()
    try await until { await link.connects == 3 && workflow.state.phase == .failed }
    await workflow.waitUntilIdle()
    #expect(await link.connects == 3)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothPassiveConnectionDoesNotInvokeFailedIndication() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.loseConnectionOnNextFeedback()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady)
    #expect(workflow.state.error == nil)
    #expect(await link.connects == 1)
    #expect(await link.feedbackCommands.isEmpty)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothResetRetiresPendingObservationWithoutClosingLiveControls() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    try await link.pushPosition()
    try await until { workflow.state.sampledAt != nil }
    await link.holdTelemetry()
    let action = Task { try await workflow.performGesture(.wave, repetitions: 1) }
    try await until { await link.writes == 1 }
    await link.resumeTelemetry()
    workflow.tryAction(.reset)
    try await until { await link.observedCommands.contains { $0.isSynchronousPositionWrite } }
    await workflow.waitUntilIdle()
    await #expect(throws: CancellationError.self) { try await action.value }
    workflow.setMotorVelocity(id: 4, value: 1)
    try await until { await link.liveCommands.contains { $0.command == 3 } }
    workflow.stopMotorControl()
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady && workflow.state.error == nil)
    #expect(await link.connects == 1)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothResetWithoutCompletionReplyDoesNotBlockNextPresetAndPreservesFailureDetail() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.configure(feedbackFailure: true)
    await #expect(throws: NexArmError.timeout) {
        try await workflow.performGesture(.wave, repetitions: 1)
    }
    #expect(workflow.state.recoveryStage != .idle)
    await link.configure()
    await workflow.waitUntilIdle()
    workflow.tryAction(.reset)  // The fixture emits no reset completion response.
    await workflow.waitUntilIdle()
    #expect(await link.observedCommands.contains { $0.isSynchronousPositionWrite })
    #expect(workflow.state.controlReady)
    try await workflow.performGesture(.wave, repetitions: 1)
    #expect(workflow.state.error == nil)
    #expect(await link.connects == 2)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) func aimFollowApproachesTheLatestCountWithoutJumpingThere() throws {
    var planner = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
    let start = Int(planner.targets[0])
    let goal = start - 80
    var last = start
    var moved = false
    for _ in 0..<100 {
        guard let proposal = try planner.approach(id: 1, target: goal) else { break }
        if let packet = proposal.packet {
            #expect(packet.isLiveControl)
            #expect(packet.id == 1)
            let position = Int(packet.payload[2]) | Int(packet.payload[3]) << 8
            #expect(abs(position - last) <= 40)
            last = position
            moved = true
        }
        planner.accept(proposal)
        #expect(abs(planner.accelerations[0]) <= NexArmJogPlanner.maximumAcceleration)
    }
    #expect(moved)
    #expect(abs(Int(planner.targets[0]) - goal) <= 2)
    #expect(try planner.approach(id: 1, target: goal) == nil)
    #expect(throws: NexArmExecutionError.invalidArguments) { try planner.approach(id: 6, target: goal) }
}

@Test(.actionCatalog) func aimFollowBrakesBeforeReversing() throws {
    var planner = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
    let start = Int(planner.targets[3])
    for _ in 0..<25 {
        if let proposal = try planner.approach(id: 4, target: start + 200) {
            planner.accept(proposal)
        }
    }
    #expect(planner.velocities[3] > 8)
    let lead = planner.targets[3]
    let brake = try #require(try planner.approach(id: 4, target: start))
    if let packet = brake.packet {
        let position = Int(packet.payload[2]) | Int(packet.payload[3]) << 8
        #expect(position <= Int(lead))
        #expect(packet.id == 4)
    }
    planner.accept(brake)
    #expect(planner.velocities[3] == 0)
    #expect(planner.targets[3] <= lead)
}

@Test(.actionCatalog, arguments: 1...5, [-2, -1, 1, 2])
func aimFinalCountRemainsPendingUntilNativeAdmission(motor: Int, delta: Int) throws {
    let initial = NexArmGesture.referenceHomeJoints
    var planner = try NexArmJogPlanner(positions: initial)
    let target = initial[motor - 1] + delta
    let proposal = try #require(try planner.approach(id: motor, target: target))
    let packet = try #require(proposal.packet)
    #expect(packet.motorTargets == [motor: target])
    // A deferred native write must leave the final intent pending, not claim it was accepted.
    #expect(planner.targets[motor - 1] == Double(initial[motor - 1]))
    let deferred = try #require(try planner.approach(id: motor, target: target))
    #expect(deferred.packet == packet)
    planner.accept(proposal)
    #expect(planner.targets[motor - 1] == Double(target))
    #expect(try planner.approach(id: motor, target: target) == nil)
    for index in 0..<6 where index != motor - 1 {
        #expect(planner.targets[index] == Double(initial[index]))
    }
}

@Test(.actionCatalog) func aimReachMotorsStayBelowTheirSlowerSpeedLimit() throws {
    var planner = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
    let start = Int(planner.targets[1])
    for _ in 0..<80 {
        guard
            let proposal = try planner.approach(
                id: 2, target: start - 300, speedLimit: NexArmJogPlanner.aimReachSpeed)
        else { break }
        planner.accept(proposal)
        #expect(abs(planner.velocities[1]) <= NexArmJogPlanner.aimReachSpeed)
    }
    #expect(planner.targets[1] < Double(start - 20))
    #expect(throws: NexArmExecutionError.invalidArguments) {
        try planner.approach(id: 2, target: start - 300, speedLimit: NexArmJogPlanner.maximumSpeed + 1)
    }
}

@Test(.actionCatalog) func bluetoothJogShapesVelocityAndRejectsConfigurationWrites() throws {
    var planner = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
    var previousAcceleration = 0.0
    var duplicates = 0
    for input in Array(repeating: 0.3, count: 35) + Array(repeating: -0.3, count: 35) {
        let proposal = try #require(try planner.proposal(id: 1, deflection: input))
        if let packet = proposal.packet { #expect(packet.isLiveControl) } else { duplicates += 1 }
        planner.accept(proposal)
        #expect(abs(planner.accelerations[0]) <= NexArmJogPlanner.maximumAcceleration)
        #expect(abs(planner.accelerations[0] - previousAcceleration) <= NexArmJogPlanner.maximumJerk * 0.03 + 0.001)
        previousAcceleration = planner.accelerations[0]
    }
    #expect(duplicates > 0)
    #expect(planner.velocities[0] < -35)
    let stopped = planner.targets
    planner.stop(id: 1)
    #expect(planner.targets == stopped && planner.velocities[0] == 0)
    #expect(try !NexArmPacket(id: 1, command: 3, payload: [40, 0]).isLiveControl)
    #expect(try !NexArmPacket(command: 51, payload: [1, 0, 8, 20, 0]).isLiveControl)
}

@Test(.actionCatalog) func bluetoothJogStickExtentControlsCruiseSpeedAndStallsDoNotCatchUp() throws {
    var slow = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
    var fast = slow
    for _ in 0..<40 {
        slow.accept(try #require(try slow.proposal(id: 1, deflection: 0.5)))
        fast.accept(try #require(try fast.proposal(id: 1, deflection: 1)))
    }
    #expect(slow.velocities[0] > 100 && slow.velocities[0] < 160)
    #expect(fast.velocities[0] > 590)
    #expect(fast.targets[0] > slow.targets[0] + 200)
    let stalled = try #require(try fast.proposal(id: 1, deflection: 1, elapsed: 2))
    #expect(stalled.target - fast.targets[0] <= 37)
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothActionFeedbackTimeoutDoesNotRecoverOrBlockNextPreset() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    try await link.pushPosition()
    try await until { workflow.state.sampledAt != nil }
    let before = await link.writes
    await link.disableTelemetry()
    await #expect(throws: NexArmExecutionError.feedbackTimeout) {
        try await workflow.performGesture(.tiltLeft, repetitions: 1)
    }
    #expect(await link.writes < before + 3)
    #expect(workflow.state.controlReady)
    #expect(workflow.state.error == nil && workflow.state.transportIssue == nil)
    #expect(await link.connects == 1)
    await link.resumeTelemetry()
    workflow.tryAction(.nod)
    await workflow.waitUntilIdle()
    #expect(await link.writes > before + 1)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothSettingsSharesFeedbackRecipeAndPreemptsPendingCompletion() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    workflow.tryAction(.wave)
    try await until { await link.observedCommands.count == 1 }
    workflow.tryAction(.tiltRight)
    await workflow.waitUntilIdle()
    #expect(await link.writes == 4)
    #expect(await link.observedCommands.count == 4)
    #expect(workflow.state.error == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothSettingsCongestionRetainsOnlyLatestTestAndResetCancelsEnding() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.blockLive(true)
    workflow.tryAction(.dance)
    try await Task.sleep(for: .milliseconds(100))
    workflow.tryAction(.tiltLeft)
    await link.blockLive(false)
    try await until { await link.observedCommands.count == 1 }
    workflow.tryAction(.reset)
    await workflow.waitUntilIdle()
    let commands = await link.observedCommands.filter { $0.isSynchronousPositionWrite }
    #expect(commands.count == 2)
    try await Task.sleep(for: .milliseconds(900))
    #expect(await link.observedCommands.filter { $0.isSynchronousPositionWrite } == commands)
    #expect(workflow.state.error == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothFeedbackHealthDoesNotCancelExecutionOrDisableManualControl() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let before = await link.observedCommands.count
    await link.health(false)
    try await until { workflow.state.transportIssue != nil }
    #expect(workflow.state.controlReady)
    #expect(workflow.state.transportIssue != nil)
    await link.health(true)
    await workflow.waitUntilIdle()
    try await until { workflow.state.controlReady }
    #expect(await link.observedCommands.count == before)
    let movement = Task { try await workflow.performGesture(.dance, repetitions: 1) }
    try await until { await link.observedCommands.count > before }
    await link.health(false)
    try await movement.value
    #expect(await link.connects == 1)
    let stopped = await link.observedCommands.count
    await link.health(true)
    await workflow.refreshDevice()
    try await until { workflow.state.controlReady }
    try await Task.sleep(for: .milliseconds(150))
    #expect(await link.observedCommands.count == stopped)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothSettingsBypassesHeldResourcesAndAgentCleanupWithFeedback() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let resources = try nexArmTestResources()
    workflow.withMotorResources = bluetoothResourceGuard(resources)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    try await resources.run(
        resources: Set((1...6).map { ResourceID(rawValue: "nexarm.motor.\($0)") }),
        owner: nil, lease: nil
    ) { @MainActor in
        workflow.tryAction(.nod)
        try await until { await link.observedCommands.count == 1 }
        #expect(workflow.state.canControl)
        #expect(!workflow.trackingAvailable)
        await workflow.stopAgentActions()
        // Agent cleanup cannot stop the second manual frame.
        try await until { await link.observedCommands.count >= 2 }
        let replacedAt = ContinuousClock.now
        workflow.tryAction(.reset)
        await workflow.waitUntilIdle()
        #expect(ContinuousClock.now - replacedAt < .seconds(1))
        let count = await link.observedCommands.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.observedCommands.count == count)
        #expect(workflow.state.canControl && workflow.state.error == nil)
        workflow.setMotorVelocity(id: 6, value: 1)
        try await until { await link.liveCommands.count > 0 }
        #expect(workflow.state.canControl && workflow.state.jogging)
        workflow.setMotorVelocity(id: 6, value: 0)
        await workflow.waitUntilIdle()
    }
    #expect(workflow.state.transportIssue == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) func bluetoothResponseTimeoutRetainsQueryAndSeparatesNotificationBytesFromPayload() {
    let missing = NexArmBluetoothFailure.responseTimeout(command: 11, expectedBytes: 24, receivedBytes: 0)
    #expect(BluetoothPresentation.failure(missing) == "读取机械臂位置回复超时（0x0B，期望载荷24字节，收到通知0字节）")
    let unmatched = NexArmBluetoothFailure.responseTimeout(command: 7, expectedBytes: 24, receivedBytes: 30)
    #expect(BluetoothPresentation.failure(unmatched) == "设备查询回复超时（0x07，期望载荷24字节，收到通知30字节）")
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothPassiveConnectionDoesNotQueryAndActualQueryTimeoutRecovers() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.dropPositions()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .connected && workflow.state.controlReady)
    #expect(await link.poseReads == 0)
    #expect(await link.connects == 1)
    await #expect(throws: NexArmError.timeout) {
        _ = try await link.exchange(NexArmPacket(command: 11), replyID: 255, replyCommand: 11, replyCount: 24)
    }
    try await until { await link.connects == 2 && workflow.state.controlReady }
    #expect(workflow.state.recoveryStage == .idle)
    #expect(await link.poseReads == 0)
    #expect(workflow.state.transportIssue == nil)
    #expect(await link.writes == 0)
    #expect(await link.feedbackCommands.isEmpty)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) func bluetoothSharedBudgetBoundsMixedProducerBurstsAndDoesNotCatchUp() {
    let start = ContinuousClock.now
    var budget = NexArmBLETrafficBudget(started: start)
    var accepted: [ContinuousClock.Instant] = []
    // Six competing motor/query producers try every millisecond for one second.
    for tick in 0..<1000 {
        let now = start.advanced(by: .milliseconds(tick))
        for _ in 0..<6 where budget.canSend(at: now, systemReady: true) {
            accepted.append(now)
            budget.sent(bytes: 14, at: now)
        }
    }
    #expect(accepted.count == 34)
    #expect(zip(accepted, accepted.dropFirst()).allSatisfy { $1 - $0 >= .milliseconds(30) })
    let afterStall = start.advanced(by: .seconds(10))
    let resumedAdmission = budget.canSend(at: afterStall, systemReady: true)
    #expect(resumedAdmission)
    budget.sent(bytes: 14, at: afterStall)
    let burstAdmission = budget.canSend(at: afterStall, systemReady: true)
    #expect(!burstAdmission)
    #expect(budget.statistics.sentBytes == 35 * 14)
}

@Test(.actionCatalog) func bluetoothSystemBackpressurePreservesBudgetForTheNextAcceptedWrite() {
    let now = ContinuousClock.now
    var budget = NexArmBLETrafficBudget(started: now)
    for _ in 0..<100 {
        let admission = budget.canSend(at: now, systemReady: false)
        #expect(!admission)
    }
    #expect(budget.nextWrite == nil)
    #expect(budget.statistics.sentPackets == 0)
    budget.resumed()
    let firstAdmission = budget.canSend(at: now, systemReady: true)
    #expect(firstAdmission)
    budget.sent(bytes: 14, at: now)
    #expect(budget.statistics.systemDeferrals == 100)
    #expect(budget.statistics.flowControlResumptions == 1)
    let earlyAdmission = budget.canSend(at: now.advanced(by: .milliseconds(29)), systemReady: true)
    let nextAdmission = budget.canSend(at: now.advanced(by: .milliseconds(30)), systemReady: true)
    #expect(!earlyAdmission && nextAdmission)
}

@Test(.actionCatalog) func bluetoothDiagnosticsDistinguishNotificationTrafficFromValidFeedback() {
    let start = ContinuousClock.now
    var budget = NexArmBLETrafficBudget(started: start)
    budget.received(bytes: 30, feedbackSamples: 1, at: start)
    // Incoming fragments/unrelated packets must not count as a fresh position sample.
    budget.received(bytes: 6, feedbackSamples: 0, at: start.advanced(by: .milliseconds(1900)))
    let stalled = budget.diagnostics(at: start.advanced(by: .seconds(2)))
    #expect(stalled.notificationBytes == 36 && stalled.feedbackSamples == 1)
    #expect(stalled.notificationGapMilliseconds == 100)
    #expect(stalled.feedbackGapMilliseconds == 2000)
    budget.received(bytes: 60, feedbackSamples: 2, at: start.advanced(by: .milliseconds(2100)))
    let recovered = budget.diagnostics(at: start.advanced(by: .milliseconds(2100)))
    #expect(recovered.feedbackSamples == 3 && recovered.feedbackGapMilliseconds == 0)
    #expect(recovered.longestFeedbackGapMilliseconds == 2100)
    #expect(NexArmBLETrafficBudget(started: start).statistics.sentPackets == 0)
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothAimSendsOnePanTiltPacketAndStopsWhenTheTargetHolds() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.throttleLive()
    try await workflow.aim(base: 0.6, pitch: 0.5)
    try await until { await link.liveCommands.count >= 1 }
    // Hold the target through the worker's idle window before explicit cancellation.
    try await Task.sleep(for: .milliseconds(400))
    let commands = await link.liveCommands
    let packet = try #require(commands.first)
    let expected = try NexArmJointCommand.positions(base: 0.6, pitch: 0.5)
    #expect(commands.count == 1)
    #expect(packet.isSynchronousPositionWrite && packet.isLiveControl)
    let addressed = try #require(packet.motorTargets)
    #expect(addressed[1] == expected[0] && addressed[4] == expected[3])
    #expect(addressed[2] == NexArmJointCommand.armHome[1])
    #expect(addressed[3] == NexArmJointCommand.armHome[2])
    #expect(Set(addressed.keys) == Set([1, 2, 3, 4]))
    await workflow.stopActions()
    #expect(workflow.state.controlReady)
    let count = commands.count
    try await Task.sleep(for: .milliseconds(100))
    #expect(await link.liveCommands.count == count)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothFeedbackLossShowsCurrentIssueWithoutRecoveryOrReplay() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let gestureCount = await link.feedbackCommands.count
    await link.health(false)
    await link.health(false)
    workflow.closePage()  // Recovery has application lifetime.
    await workflow.waitUntilIdle()
    try await until { workflow.state.transportIssue != nil }
    #expect(await link.connects == 1 && workflow.state.controlReady)
    #expect(await link.feedbackCommands.count == gestureCount)
    #expect(workflow.state.transportIssue != nil)
    #expect(workflow.state.recoveryStage == .idle)
    #expect(await link.liveCommands.isEmpty)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothCongestionResetsInputsAndOnlyNewIntentCanSendAfterRecovery() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.blockLive(true)
    workflow.setMotorVelocity(id: 1, value: 1)
    try await until { await link.connects == 2 && workflow.state.controlReady }
    await link.blockLive(false)
    try await Task.sleep(for: .milliseconds(150))
    #expect(await link.liveCommands.isEmpty)
    #expect(workflow.state.transportIssue == nil)
    workflow.setMotorVelocity(id: 1, value: 0.5)
    try await until { await !link.liveCommands.isEmpty }
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothQueryIsolationIsClearedByANewVerifiedConnection() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.failPositionOnce()
    await #expect(throws: NexArmError.timeout) {
        _ = try await link.exchange(NexArmPacket(command: 11), replyID: 255, replyCommand: 11, replyCount: 24)
    }
    try await until { await link.connects == 2 && workflow.state.controlReady }
    await workflow.waitUntilIdle()
    #expect(await link.connects == 2)
    #expect(workflow.state.controlReady)
    #expect(await !link.status().queriesQuarantined)
    #expect(workflow.state.transportIssue == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothLatestCommunicationIssueClearsWhenFeedbackRecovers() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.publishFeedback(try NexArmPacket(command: 11, payload: [0]))
    await workflow.refreshDevice()
    #expect(workflow.state.transportIssue == nil)
    await link.health(false)
    try await until { workflow.state.transportIssue != nil }
    #expect(workflow.state.status(for: try link.businessID) == "已连接，异常")
    #expect(workflow.state.canControl(try link.businessID))
    await link.health(true)
    try await until { workflow.state.transportIssue == nil }
    #expect(workflow.state.status(for: try link.businessID) == "已连接")
    #expect(await link.connects == 1)
    await link.health(false)
    try await until { workflow.state.transportIssue != nil }
    await link.health(true)
    try await until { workflow.state.transportIssue == nil }
    workflow.disconnect()
    await workflow.waitUntilIdle()
    #expect(!workflow.state.canControl(try link.businessID))
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothRecoveryStopsAfterThreeFailuresAndManualReconnectStartsAFreshEpisode() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.failConnections(3)
    await link.loseConnection()
    try await until { workflow.state.recoveryStage == .failed }
    await workflow.waitUntilIdle()
    #expect(await link.connects == 4)
    #expect(workflow.state.recoveryAttempt == 3 && !workflow.state.controlReady)
    try await Task.sleep(for: .milliseconds(150))
    #expect(await link.connects == 4)
    workflow.reconnect(try link.businessID)
    await workflow.waitUntilIdle()
    #expect(await link.connects == 5)
    #expect(workflow.state.controlReady && workflow.state.recoveryAttempt == 0)
    #expect(workflow.state.transportIssue == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothUnconfirmedDisconnectNeverOpensASecondConnection() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.refuseDisconnect(true)
    await link.loseConnection()
    try await until { workflow.state.recoveryStage == .failed }
    #expect(await link.connects == 1 && !workflow.state.controlReady)
    #expect(workflow.state.error != nil)
    #expect(workflow.state.recoveryStage == .failed)
    await workflow.waitUntilIdle()
    await link.power(.poweredOff)
    try await until { workflow.state.availability == .poweredOff }
    await link.power(.poweredOn)
    try await until { workflow.state.availability == .available }
    await workflow.waitUntilIdle()
    #expect(workflow.state.recoveryStage == .failed)
    #expect(workflow.state.error != nil)
    #expect(await link.connects == 1)
    await link.refuseDisconnect(false)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothRecoveryWaitsForPowerAndUserDisconnectCancelsPendingRetries() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.power(.poweredOff)
    try await until { workflow.state.recoveryStage == .waitingForBluetooth }
    #expect(await link.connects == 1)
    await link.power(.poweredOn)
    try await until { await link.connects == 2 && workflow.state.controlReady }
    await link.loseConnection()
    try await until { workflow.state.recoveryStage == .waiting }
    workflow.disconnect()
    await workflow.waitUntilIdle()
    try await Task.sleep(for: .milliseconds(1200))
    #expect(await link.connects == 2)
    #expect(!workflow.state.controlReady)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothOldSnapshotsCannotReviveOrFloodARecovery() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.setRevision(100)
    var old = await link.status()
    old.revision = 99
    old.feedbackHealthy = false
    await link.lateSnapshot(old)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await link.connects == 1)
    #expect(workflow.state.controlReady)
    // Use unversioned fixture events again; production publishes increasing revisions.
    await link.setRevision(0)
    await link.loseConnection()
    try await until { workflow.state.recoveryStage == .waiting }
    let ids = (0..<5).map { _ in UUID().uuidString }
    for id in ids { for _ in 0..<40 { workflow.connect(id) } }
    #expect(workflow.state.error == "正在恢复连接，请等待完成或先断开")
    #expect(await link.connects == 1)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothEveryRecoverySuccessResetsItsEpisodeBudget() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    for count in 2...6 {
        await link.loseConnection()
        try await until { await link.connects == count && workflow.state.controlReady }
        await workflow.waitUntilIdle()
        #expect(workflow.state.recoveryAttempt == 0)
        #expect(workflow.state.recoveryStage == .idle)
    }
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothForegroundAfterExhaustionAlwaysStartsANewEligibleEpisode() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    for count in [4, 7] {
        await link.failConnections(3)
        if count == 4 { await link.loseConnection() } else { workflow.setForeground(true) }
        try await until { workflow.state.recoveryStage == .failed }
        await workflow.waitUntilIdle()
        #expect(await link.connects == count)
        #expect(workflow.state.recoveryAttempt == 3)
        workflow.setForeground(true)
        await workflow.waitUntilIdle()
        #expect(await link.connects == count)
        workflow.setForeground(false)
        await workflow.waitUntilIdle()
    }
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(await link.connects == 8)
    #expect(workflow.state.controlReady && workflow.state.recoveryAttempt == 0)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothRepeatedBackgroundPreservesHealthyLinkAndNeverResumesOldJog() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    workflow.setMotorVelocity(id: 1, value: 0.8)
    try await until(context: "initial jog before repeated background") { await !link.liveCommands.isEmpty }
    for _ in 0..<5 {
        workflow.setForeground(false)
        workflow.setForeground(true)
        workflow.setForeground(false)
        workflow.setForeground(true)
        await workflow.waitUntilIdle()
        #expect(workflow.state.controlReady && !workflow.state.jogging)
        #expect(workflow.state.recoveryAttempt == 0)
        #expect(await link.connects == 1)
        #expect(await link.disconnects == 0)
    }
    let commands = await link.liveCommands.count
    try await Task.sleep(for: .milliseconds(100))
    #expect(await link.liveCommands.count == commands)
    workflow.setMotorVelocity(id: 1, value: -0.8)
    try await until(context: "fresh jog after repeated background") { await link.liveCommands.count > commands }
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothForegroundJoinsSuspendedWriterBeforeAdmittingNewControl() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.blockLiveEnd()
    workflow.setMotorVelocity(id: 1, value: 0.8)
    try await until { await !link.liveCommands.isEmpty }
    workflow.setForeground(false)
    try await until { await link.waitingForLiveEnd }
    workflow.setForeground(true)
    let commands = await link.liveCommands.count
    workflow.tryAction(.nod)
    workflow.setMotorVelocity(id: 2, value: 1)
    await #expect(throws: NexArmExecutionError.busy) { try await workflow.resetArm() }
    #expect(!workflow.trackingAvailable)
    #expect(await link.liveCommands.count == commands)
    #expect(await link.observedCommands.isEmpty)
    #expect(await link.connects == 1)
    await link.releaseLiveEnd()
    await workflow.waitUntilIdle()
    #expect(workflow.trackingAvailable)
    #expect(await link.disconnects == 0)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothLossWhileBackgroundedWaitsForForegroundThenReconnects() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    await link.loseConnection()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await link.connects == 1)
    #expect(workflow.state.recoveryAttempt == 0)
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(await link.connects == 2)
    #expect(workflow.state.controlReady && workflow.state.recoveryAttempt == 0)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothBackgroundCancelsRecoveryAndForegroundResumesWithoutOldAim() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    try await workflow.aim(base: 0.8, pitch: 0.5)
    try await until { await !link.liveCommands.isEmpty }
    await link.loseConnection()
    try await until { workflow.state.recoveryStage == .waiting }
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    #expect(workflow.state.recoveryStage == .suspended)
    #expect(await link.connects == 1)
    #expect(workflow.state.recoveryAttempt == 0)
    let oldCommandCount = await link.liveCommands.count
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady && workflow.state.recoveryAttempt == 0)
    #expect(await link.connects == 2)
    #expect(await link.liveCommands.count == oldCommandCount)
    try await workflow.aim(base: -0.8, pitch: -0.5)
    try await until { await link.liveCommands.count > oldCommandCount }
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothForgetDuringBackoffDisablesSavedRecovery() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.loseConnection()
    try await until { workflow.state.recoveryStage == .waiting }
    workflow.forget()
    await workflow.waitUntilIdle()
    #expect(workflow.state.selected == nil && workflow.state.remembered == nil)
    await link.power(.poweredOn)
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(await link.connects == 1)
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothRevokedExecutionPermitCannotBypassAgentGuard() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    workflow.withMotorResources = bluetoothResourceGuard(try nexArmTestResources())
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let oldPermit = ResourceExecutionPermit { _ in throw HarnessError.notRunning }
    let held = Set((1...5).map { ResourceID(rawValue: "nexarm.motor.\($0)") })
    await #expect(throws: NexArmExecutionError.self) {
        try await ResourceExecutionContext.$held.withValue(held) {
            try await ResourceExecutionContext.$permit.withValue(oldPermit) {
                try await workflow.resetArm()
            }
        }
    }
    #expect(await link.observedCommands.isEmpty)
    #expect(workflow.state.controlReady && workflow.state.error == nil && workflow.state.transportIssue == nil)
    #expect(await link.connects == 1)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

func bluetoothResourceGuard(_ resources: ResourceCoordinator)
    -> @Sendable (Set<Int>, @escaping @Sendable () async throws -> Void) async throws -> Void
{
    { motors, operation in
        do {
            let requested = Set(motors.map { ResourceID(rawValue: "nexarm.motor.\($0)") })
            let owner = ResourceExecutionContext.owner
            let lease =
                if let owner { await resources.lease(for: owner, resources: requested) } else { nil as ResourceLease? }
            try await resources.run(
                resources: requested, owner: owner, lease: lease, operation: operation)
        } catch ResourceError.busy {
            throw NexArmExecutionError.resourceBusy
        } catch let error as ResourceError {
            throw NexArmExecutionError.resourceUnavailable(String(describing: error))
        }
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [1, 5]) @MainActor
func bluetoothAssistantActionPreemptsTrackingAndKeepsQueuedActions(motor: Int) async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let resources = try ResourceCoordinator(
        definitions: (1...6).map {
            ResourceDefinition(
                id: ResourceID(rawValue: "nexarm.motor.\($0)"), allowedOwners: [.assistant, .photographer],
                executionGroup: ResourceID(rawValue: "nexarm.writer"), preempts: [.assistant: [.photographer]]
            ) { await workflow.stopAgentActions() }
        })
    workflow.withMotorResources = bluetoothResourceGuard(resources)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let photographer = ExecutionOwner(
        agent: .photographer, incarnation: UUID().uuidString, sessionID: UUID().uuidString)
    try await ResourceExecutionContext.$owner.withValue(photographer) {
        try await workflow.aim(base: -0.8, pitch: 0.4)
    }
    try await until { await !link.liveCommands.isEmpty }
    await link.blockLiveEnd()
    await link.holdTelemetry()
    let module = NexArmGestureModule { request, invocation in
        try await workflow.moveMotor(
            id: try #require(request.motor), target: request.target, speed: request.speed,
            acceleration: request.acceleration,
            recordReport: { try await invocation.results.record($0) })
    }
    let scheduler = ChannelScheduler(registry: try ActionRegistry(modules: [module]), resources: resources)
    let session = UUID().uuidString
    let input = AgentInput(
        id: UUID().uuidString, sessionID: session, payload: .text("Explicit user movement"))
    let owner = ExecutionOwner(agent: .assistant, incarnation: UUID().uuidString, sessionID: session)
    for target in [2000, 2100] {
        let call = ActionCall(
            actionPath: ActionPath(domain: "NexArm", module: "Motion", function: "moveMotor"), channel: "Robot",
            parameters: ["motor": String(motor), "target": String(target)])
        _ = try await scheduler.enqueue(
            invocation: ScheduledAction(
                envelope: OutputEnvelope(source: .assistant, input: input, output: .actionCall(call)),
                owner: owner))
    }
    try await until { await link.waitingForLiveEnd }
    #expect(await link.observedCommands.isEmpty)
    #expect(await scheduler.executionSnapshot().records.filter { $0.phase == .queued }.count == 1)
    await link.releaseLiveEnd()
    try await until { await link.observedCommands.count == 1 }
    await #expect(throws: NexArmExecutionError.busy) { try await workflow.aim(base: 0.8, pitch: -0.4) }
    await link.resumeTelemetry()
    try await scheduler.finish(inputID: input.id, source: .assistant)
    let records = await scheduler.executionSnapshot().records
    #expect(records.count == 2 && records.allSatisfy { $0.phase == .succeeded })
    let stopped = await link.liveCommands.count
    try await Task.sleep(for: .milliseconds(100))
    #expect(await link.liveCommands.count == stopped)
    try await ResourceExecutionContext.$owner.withValue(photographer) {
        try await workflow.aim(base: 0.5, pitch: -0.3)
    }
    try await until { await link.liveCommands.count > stopped }
    await resources.close(sessionID: photographer.sessionID)
    #expect(workflow.state.controlReady && workflow.state.error == nil && workflow.state.transportIssue == nil)
    #expect(await link.connects == 1)
    await scheduler.shutdown()
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothTrackingInputExpiryJoinsWriterAndReleasesMotorResources() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let resources = try nexArmTestResources()
    workflow.withMotorResources = bluetoothResourceGuard(resources)
    let session = UUID().uuidString
    let photographer = try PhotographerAgent(
        sessionID: session, controlsArm: true,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
    )
    try await photographer.start()
    let pose = try PoseObservation(
        width: 100, height: 100, sequence: 1, timestamp: 1e12, rotation: 1,
        people: [Array(repeating: .init(x: 50, y: 50, confidence: 0.9), count: 17)])
    let payload = InputPayload.observation(.pose(pose))
    workflow.trackingInputAvailable = { await photographer.hasFreshPose() }
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    try await photographer.receive(
        AgentInput(
            id: UUID().uuidString,
            sessionID: session, payload: payload,
            metadata: InputMetadata(payload: payload, source: "visionPerception", rootID: UUID().uuidString))
    )
    await link.blockLiveEnd()
    try await workflow.aim(base: -0.8, pitch: 0.4)
    try await until { await !link.liveCommands.isEmpty }
    try await until { await link.waitingForLiveEnd }
    await #expect(throws: ResourceError.busy) {
        try await resources.run(resources: [ResourceID(rawValue: "nexarm.motor.1")], owner: nil, lease: nil) {}
    }
    await link.releaseLiveEnd()
    await workflow.waitUntilIdle()
    try await resources.run(resources: [ResourceID(rawValue: "nexarm.motor.1")], owner: nil, lease: nil) {}
    let stopped = await link.liveCommands.count
    try await Task.sleep(for: .milliseconds(100))
    #expect(await link.liveCommands.count == stopped)
    #expect(workflow.state.error == nil && workflow.state.controlReady && workflow.state.transportIssue == nil)
    #expect(await link.connects == 1)
    await photographer.stop()
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothGatewayAimUpdatesUseOneWorkerAndKeepActualMotorExclusion() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let resources = try nexArmTestResources()
    workflow.withMotorResources = bluetoothResourceGuard(resources)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let session = UUID().uuidString
    let photographer = try PhotographerAgent(
        sessionID: session, controlsArm: true,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
    )
    let manager = AgentManager()
    try await manager.register(photographer, sessionID: session)
    try await photographer.start()
    let tools = try ToolRegistry(modules: [
        NexArmTrackingModule { base, pitch, _ in try await workflow.aim(base: base, pitch: pitch) }
    ])
    let output = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, allowsExternalSend: true), tools: tools,
        actions: ChannelScheduler(registry: ActionRegistry(), resources: resources), sink: { _ in })
    for sequence: UInt64 in 1...8 {
        let call = ToolCall(
            id: UUID().uuidString,
            toolPath: "NexArm.Tracking.aim", arguments: ["base": String(0.5 + Double(sequence) / 100), "pitch": "0.5"])
        let result = try await output.dispatch(
            OutputEnvelope(
                source: .photographer,
                input: AgentInput(
                    id: UUID().uuidString, sessionID: session, payload: .text("Test tracking intent")),
                output: .toolCall(call), sequence: sequence))
        #expect(result == nil)
    }
    try await until { await !link.liveCommands.isEmpty }
    await #expect(throws: ResourceError.busy) {
        try await resources.run(resources: [ResourceID(rawValue: "nexarm.motor.1")], owner: nil, lease: nil) {
            Issue.record("A competing motor write must not enter")
        }
    }
    #expect(workflow.state.error == nil && workflow.state.controlReady)
    #expect(await link.connects == 1)
    await output.cancel(sessionID: session)
    let stopped = await link.liveCommands.count
    try await Task.sleep(for: .milliseconds(100))
    #expect(await link.liveCommands.count == stopped)
    try await resources.run(resources: [ResourceID(rawValue: "nexarm.motor.1")], owner: nil, lease: nil) {}
    try await workflow.aim(base: -0.6, pitch: -0.5)
    #expect(workflow.state.error == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    await output.shutdown()
    await photographer.stop()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothAimResourceConflictDoesNotChangeNativeStateAndFreshTargetCanStart() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let resources = try nexArmTestResources()
    workflow.withMotorResources = bluetoothResourceGuard(resources)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let competing = Task {
        try await resources.run(resources: [ResourceID(rawValue: "nexarm.motor.1")], owner: nil, lease: nil) {
            entered.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }
    var started = entered.stream.makeAsyncIterator()
    _ = await started.next()
    await #expect(throws: NexArmExecutionError.resourceBusy) {
        try await workflow.aim(base: 0.6, pitch: 0.5)
    }
    #expect(workflow.state.controlReady)
    #expect(workflow.state.error == nil)
    #expect(workflow.state.transportIssue == nil)
    #expect(await link.connects == 1)
    #expect(await link.liveCommands.isEmpty)
    release.continuation.yield(())
    try await competing.value
    try await workflow.aim(base: -0.6, pitch: -0.5)
    try await until { await !link.liveCommands.isEmpty }
    #expect(workflow.state.error == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) @MainActor
func bluetoothManualControlsStayEnabledDuringActiveMotionAndRefresh() {
    let state = BluetoothSettingsState()
    state.phase = .connected
    state.jogging = true
    #expect(state.canControl)
    state.recoveryStage = .cleaning
    #expect(!state.canControl)
    state.recoveryStage = .idle
    #expect(state.canControl)
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothSettingsOverridesAgentMotionAndAimWithSharedRecipe() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let resources = try nexArmTestResources()
    workflow.withMotorResources = bluetoothResourceGuard(resources)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    try await link.pushPosition()
    try await until { workflow.state.sampledAt != nil }
    await link.holdTelemetry()
    let observedBefore = await link.observedCommands.count
    let action = Task { try await workflow.performGesture(.wave, repetitions: 1) }
    try await until { await link.observedCommands.count == observedBefore + 1 }
    let firstAgentPacket = try #require(await link.observedCommands.last)
    let reads = await link.poseReads
    workflow.tryAction(.wave)
    try await until { await link.observedCommands.count == observedBefore + 2 }
    #expect(await link.observedCommands.last == firstAgentPacket)
    #expect(workflow.state.canControl)
    await #expect(throws: CancellationError.self) { try await action.value }
    workflow.setMotorVelocity(id: 1, value: 1)
    try await until { await link.liveCommands.count >= 1 }
    workflow.setMotorVelocity(id: 1, value: 0)
    await workflow.waitUntilIdle()
    let afterManual = await link.liveCommands.count
    try await workflow.aim(base: -0.5, pitch: 0.3)
    try await until { await link.liveCommands.count > afterManual }
    let beforeTakeover = await link.liveCommands.count
    workflow.setMotorVelocity(id: 6, value: 1)
    try await until { await link.liveCommands.dropFirst(beforeTakeover).contains { $0.id == 6 } }
    #expect(workflow.state.canControl && workflow.state.jogging)
    workflow.stopMotorControl()
    await workflow.waitUntilIdle()
    #expect(await link.poseReads == reads)
    #expect(workflow.state.error == nil && workflow.state.controlReady)
    #expect(workflow.state.transportIssue == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothPassiveRefreshNeverBlocksManualResetOrIssuesQuery() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.holdTelemetry()
    let refresh = Task { await workflow.refreshDevice() }
    await refresh.value
    #expect(await link.poseReads == 0)
    #expect(workflow.state.canControl)
    let started = ContinuousClock.now
    workflow.tryAction(.reset)
    try await until { await link.observedCommands.count == 1 }
    await link.resumeTelemetry()
    await workflow.waitUntilIdle()
    await refresh.value
    #expect(ContinuousClock.now - started < .seconds(1))
    #expect(await link.observedCommands.count == 1)
    #expect(await link.connects == 1)
    #expect(workflow.state.controlReady && workflow.state.error == nil)
    #expect(workflow.state.transportIssue == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothLatestSliderSupersedesPresetWhileOldAimCleanupIsJoining() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let resources = try nexArmTestResources()
    workflow.withMotorResources = bluetoothResourceGuard(resources)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    try await workflow.aim(base: -0.6, pitch: 0.3)
    try await until { await link.liveCommands.count > 0 }
    await link.blockLiveEnd()
    let before = await link.liveCommands.count
    workflow.tryAction(.dance)
    try await until { await link.waitingForLiveEnd }
    // The old writer remains held while the Settings supervisor joins it.
    try await Task.sleep(for: .milliseconds(20))
    workflow.setMotorVelocity(id: 6, value: 1)
    await link.releaseLiveEnd()
    try await until { await link.liveCommands.dropFirst(before).contains { $0.id == 6 } }
    workflow.stopMotorControl()
    await workflow.waitUntilIdle()
    #expect(await link.liveCommands.dropFirst(before).allSatisfy { !$0.isSynchronousPositionWrite })
    #expect(workflow.state.error == nil && workflow.state.canControl)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

/// Explicit simulated streaming model: generation remains pending across the device outage.
private actor BluetoothRecoveryChat: ChatCapability {
    let availability: CapabilityAvailability = .available
    private var emitter: InferenceEmitter<ChatEvent>?
    private(set) var requests = 0
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests += 1
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if requests > 1 {
            try pair.emitter.yield(.text("已收到机械臂执行结果，不会自动重复动作。"))
            try pair.emitter.yield(.finished(.stop))
            pair.emitter.finish()
            return pair.session
        }
        emitter = pair.emitter
        try pair.emitter.yield(
            .text("第一句。<shakeBase cycles=\"1\"/><shakeBase cycles=\"1\"/>第二句。<wait></wait>"))
        return pair.session
    }
    func finishReply() throws {
        let emitter = try #require(emitter)
        try emitter.yield(.text("第三句。"))
        try emitter.yield(.finished(.stop))
        emitter.finish()
    }
}

private enum BluetoothRecoveryTestFault: Sendable, CaseIterable {
    case disconnected, congestion, radioOff, exhausted
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: BluetoothRecoveryTestFault.allCases) @MainActor
private func bluetoothRecoveryPreservesAssistantGenerationSpeechAndOtherActions(
    fault: BluetoothRecoveryTestFault
) async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let chat = BluetoothRecoveryChat()
    let assistant = try AgentChatWorker<AssistantContextState>(
        stateContext: try publicStateFixture(),
        chat: chat,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    let speech = try await bindSpeechRequests(assistant)
    let manager = AgentManager()
    let session = UUID().uuidString
    try await manager.register(assistant, sessionID: session)
    try await assistant.start()
    let photographer = try PhotographerAgent(
        sessionID: session, controlsArm: true,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
    )
    try await manager.register(photographer, sessionID: session)
    try await photographer.start()
    let input = InputGateway(manager: manager, allowsExternalSend: true)
    let releaseSpeech = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var spoken: [String] = []
    var expressions = 0
    let speechPath = ActionPath(domain: "Speech", module: "Playback", function: "speak")
    let expressionPath = ActionPath(domain: "UI", module: "Expression", function: "setExpression")
    let registry = try ActionRegistry(
        definitions:
            NexArmBaseModule { count, invocation in
                try await workflow.shakeBase(cycles: count, recordReport: { try await invocation.results.record($0) })
            }.definitions.map { ActionBinding(function: $0) } + [
                ActionBinding(
                    path: speechPath, displayName: "Simulated speech", kind: .finite, completion: "Gate released.",
                    handler: { invocation in
                        let id = try #require(invocation.call.parameters["audioID"])
                        let text = try #require(await speech.text(id))
                        let first = await MainActor.run { spoken.isEmpty }
                        await MainActor.run { spoken.append(text) }
                        if first {
                            var iterator = releaseSpeech.stream.makeAsyncIterator()
                            _ = await iterator.next()
                            try Task.checkCancellation()
                        }
                    }),
                ActionBinding(
                    path: expressionPath, displayName: "Simulated presentation", kind: .state,
                    completion: "State accepted.",
                    handler: { _ in
                        await MainActor.run { expressions += 1 }
                    }),
                ActionBinding(
                    path: ActionPath(domain: "UI", module: "Caption", function: "print"),
                    displayName: "Simulated captions", kind: .state, completion: "Accepted.",
                    handler: { _ in await MainActor.run { expressions += 1 } }),
            ])
    let scheduler = ChannelScheduler(registry: registry, resources: try nexArmTestResources()) {
        await input.deliverActionResult($0)
    }
    let tools = try ToolRegistry(modules: [
        NexArmTrackingModule { base, pitch, _ in try await workflow.aim(base: base, pitch: pitch) }
    ])
    try await tools.registerCompletion("UI.Caption.print") { _ in }
    let output = OutputGateway(
        manager: manager, requests: input, tools: tools, actions: scheduler, actionFeedback: .terminal, sink: { _ in })
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let observedBefore = await link.observedCommands.count
    try await link.pushPosition()
    try await until { workflow.state.joints.count == 6 }
    await link.holdTelemetry()
    let request = AgentInput(
        id: UUID().uuidString, sessionID: session,
        payload: .text("Continue a reply while the robot recovers"))
    let pump = Task { () throws -> Bool in
        for await envelope in fixtureOutputs(assistant) {
            let result = try await output.execute(envelope)
            #expect(!result.isError)
            if envelope.output == .control("agent.finished") { return true }
        }
        return false
    }
    _ = try await input.send(request, to: .assistant)
    try await until(context: "reply admission and active robot write") {
        let records = await scheduler.executionSnapshot().records
        let writing = await link.observedCommands.count > observedBefore
        return records.filter { $0.path.domain == "NexArm" }.count == 2
            && records.filter { $0.path == speechPath }.count == 2
            && spoken.count == 1 && writing
    }
    switch fault {
    case .disconnected: await link.loseConnection()
    case .congestion:
        await link.configure(fail: true)
        await link.resumeTelemetry()
    case .radioOff: await link.power(.poweredOff)
    case .exhausted:
        await link.failConnections(3)
        await link.loseConnection()
    }
    try await until(context: "device cleanup completed") {
        workflow.state.recoveryStage == (fault == .radioOff ? .waitingForBluetooth : .waiting)
    }
    await link.configure()
    await link.resumeTelemetry()
    let failedTool = try await output.execute(
        OutputEnvelope(
            source: .photographer,
            input: AgentInput(
                id: UUID().uuidString, sessionID: session, payload: .text("Unavailable robot")),
            output: .toolCall(
                ToolCall(
                    id: UUID().uuidString, toolPath: "NexArm.Tracking.aim",
                    arguments: ["base": "0.5", "pitch": "0.5"])),
            sequence: 1)
    )
    #expect(failedTool.isError && failedTool.tool?.isError == true)
    #expect(await assistant.status().lifecycle == .running)
    #expect(await photographer.status().lifecycle == .running)
    if fault == .radioOff { await link.power(.poweredOn) }
    if fault == .exhausted {
        try await until { workflow.state.recoveryStage == .failed }
        #expect(await link.connects == 4)
        #expect(await assistant.status().lifecycle == .running && spoken.count == 1)
        workflow.reconnect(try link.businessID)
    }
    let expectedConnections = fault == .exhausted ? 5 : 2
    try await until(context: "verified replacement connection") {
        await link.connects == expectedConnections && workflow.state.controlReady
    }
    let writesAfterRecovery = await link.writes
    #expect(spoken.count == 1)
    let interrupted = await scheduler.executionSnapshot().records.filter { $0.path.domain == "NexArm" }
    #expect(interrupted.count == 2)
    let robotStopped = interrupted.allSatisfy { $0.phase == .failed }
    #expect(robotStopped)
    // Both robot handlers fail normally while offline; generation and unrelated lanes continue.
    try await chat.finishReply()
    releaseSpeech.continuation.yield(())
    releaseSpeech.continuation.finish()
    #expect(try await pump.value)
    await scheduler.finishResultDelivery()
    let armResults = await assistant.actionResults().filter { $0.path.domain == "NexArm" }
    let needsReply = armResults.contains { $0.status != .succeeded }
    #expect(await chat.requests == (needsReply ? 2 : 1))
    #expect(spoken == ["第一句。", "第二句。", "第三句。"] + (needsReply ? ["已收到机械臂执行结果，不会自动重复动作。"] : []))
    #expect(expressions == (needsReply ? 4 : 3))
    #expect(await link.writes == writesAfterRecovery)
    let records = await scheduler.executionSnapshot().records
    let otherSucceeded = records.filter { $0.path == speechPath || $0.path == expressionPath }.allSatisfy {
        $0.phase == .succeeded
    }
    #expect(otherSucceeded)
    #expect(await assistant.actionResults().filter { $0.path.domain == "NexArm" }.count == 2)
    // A subsequent explicit command uses the replacement connection normally.
    try await workflow.shakeBase(cycles: 1)
    #expect(await link.writes > writesAfterRecovery)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    await output.shutdown()
    await assistant.stop()
    await photographer.stop()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothManualSegmentsRequireFeedbackAndResetCanReplacePendingArrival() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let baseline = await link.observedCommands.count
    await link.holdTelemetry()
    let submitted = ContinuousClock.now
    workflow.tryAction(.nod)
    #expect(ContinuousClock.now - submitted < .milliseconds(100))
    try await until { await link.observedCommands.count == baseline + 1 }
    await workflow.stopAgentActions()
    try await Task.sleep(for: .milliseconds(250))
    #expect(await link.observedCommands.count == baseline + 1)
    #expect(workflow.state.canControl)
    await link.resumeTelemetry()
    try await until { await link.observedCommands.count >= baseline + 2 }
    await link.holdTelemetry()
    let beforeReset = await link.observedCommands.count
    let replaced = ContinuousClock.now
    workflow.tryAction(.reset)
    try await until { await link.observedCommands.count == beforeReset + 1 }
    #expect(ContinuousClock.now - replaced < .seconds(1))
    #expect(workflow.state.canControl)
    let reset = try #require(await link.observedCommands.last)
    #expect(reset.isSynchronousPositionWrite)
    await link.resumeTelemetry()
    await workflow.waitUntilIdle()
    #expect(await link.observedCommands.count == beforeReset + 1)
    #expect(workflow.state.error == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothManualNodAdvancesOnArrivalWithoutNominalFrameDelay() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let baseline = await link.observedCommands.count
    let start = ContinuousClock.now
    workflow.tryAction(.nod)
    await workflow.waitUntilIdle()
    #expect(ContinuousClock.now - start < .seconds(2))
    #expect(await link.observedCommands.count == baseline + 6)
    #expect(workflow.state.error == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothPassiveConnectionDoesNotProbeAndFeedbackLossKeepsManualControl() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .connected && workflow.state.canControl)
    #expect(await link.poseReads == 0)
    #expect(await link.versionReads == 0)
    #expect(await link.feedbackCommands.isEmpty)
    #expect(await link.observedCommands.isEmpty)
    await link.health(false)
    try await until { workflow.state.transportIssue != nil }
    #expect(workflow.state.canControl && workflow.state.controlReady)
    await workflow.refreshDevice()
    #expect(await link.poseReads == 0)
    #expect(await link.connects == 1)
    #expect(await link.disconnects == 0)
    await link.disableTelemetry()
    workflow.tryAction(.nod)
    try await until(context: "first Action native write") { await link.observedCommands.count == 1 }
    workflow.tryAction(.reset)
    try await until { await link.observedCommands.count == 2 }
    workflow.setMotorVelocity(id: 4, value: 1)
    try await until { await link.liveCommands.count > 0 }
    workflow.stopMotorControl()
    await workflow.waitUntilIdle()
    #expect(workflow.state.canControl && workflow.state.error == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) @MainActor
func bluetoothManualButtonsOnlyRequireConnectedLink() {
    let state = BluetoothSettingsState()
    state.phase = .connected
    #expect(state.canControl)
    state.phase = .disconnecting
    #expect(!state.canControl)
}

/// Recovery can finish while a failed handler is still publishing its result.
@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothRecoveryLeavesQueuedActionsForNormalChannelExecution() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let assistant = try AgentChatWorker<AssistantContextState>(
        stateContext: try publicStateFixture(),
        chat: BluetoothRecoveryChat(),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    let manager = AgentManager()
    let session = UUID().uuidString
    try await manager.register(assistant, sessionID: session)
    try await assistant.start()
    let inputGateway = InputGateway(manager: manager, allowsExternalSend: true)
    let releaseFailure = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var attempts = 0
    var firstFailed = false
    let registry = try ActionRegistry(
        definitions: NexArmBaseModule { count, invocation in
            let first = await MainActor.run {
                attempts += 1
                return attempts == 1
            }
            do {
                try await workflow.shakeBase(cycles: count, recordReport: { try await invocation.results.record($0) })
            } catch {
                if first {
                    #expect(!(error is CancellationError))
                    await MainActor.run { firstFailed = true }
                    var iterator = releaseFailure.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    try Task.checkCancellation()
                }
                throw error
            }
        }.definitions.map { ActionBinding(function: $0) })
    let scheduler = ChannelScheduler(registry: registry, resources: try nexArmTestResources()) {
        await inputGateway.deliverActionResult($0)
    }
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    try await link.pushPosition()
    try await until { workflow.state.joints.count == 6 }
    await link.holdTelemetry()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: session, payload: .text("Two accepted robot actions"))
    let owner = ExecutionOwner(
        agent: .assistant, incarnation: try await manager.identity(.assistant), sessionID: session)
    let call = ActionCall(
        actionPath: ActionPath(domain: "NexArm", module: "Motion", function: "shakeBase"), channel: "Robot",
        parameters: ["cycles": "1"])
    func invocation() throws -> ScheduledAction {
        try ScheduledAction(
            envelope: OutputEnvelope(source: .assistant, input: input, output: .actionCall(call)),
            owner: owner,
            feedback: .terminal)
    }
    _ = try await scheduler.enqueue(invocation: invocation())
    _ = try await scheduler.enqueue(invocation: invocation())
    try await until(context: "first Action native write") { await link.observedCommands.count == 1 }
    await link.loseConnection()
    try await until(context: "first Action failed normally") { firstFailed }
    await link.resumeTelemetry()
    try await until { await link.connects == 2 && workflow.state.controlReady }
    #expect(attempts == 1)
    let retained = await scheduler.executionSnapshot().records
    #expect(retained.filter { $0.phase == .queued }.count == 1)
    #expect(!retained.contains { $0.phase == .cancelled })
    let writesBeforeSecond = await link.observedCommands.count
    releaseFailure.continuation.yield(())
    releaseFailure.continuation.finish()
    try await scheduler.finish(inputID: input.id, source: .assistant)
    await scheduler.finishResultDelivery()
    #expect(attempts == 2)
    #expect(await link.observedCommands.count > writesBeforeSecond)
    let results = await assistant.actionResults()
    #expect(results.count == 2)
    #expect(results.filter { $0.status == .failed }.count == 1)
    #expect(results.filter { $0.status == .succeeded }.count == 1)
    let failure = try #require(results.first { $0.status == .failed })
    #expect(failure.report?.entries.contains(where: { $0.code?.rawValue == "disconnected" }) == true)
    #expect(failure.report?.isCancelled == false)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    await scheduler.shutdown()
    await assistant.stop()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothReconnectDoesNotWaitForOldActionCompletionToShowConnected() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    try await link.pushPosition()
    try await until { workflow.state.joints.count == 6 }
    await link.holdTelemetry()
    await link.blockObservationEnd()
    defer { Task { await link.releaseObservationEnd() } }
    let action = Task { try await workflow.shakeBase(cycles: 1) }
    try await until { await link.observedCommands.count == 1 }
    await link.loseConnection()
    try await until { await link.waitingForObservationEnd }
    // The old business operation has not returned, but the native session is already closed.
    try await until { await link.connects == 2 && workflow.state.phase == .connected }
    #expect(await link.waitingForObservationEnd)
    let currentDeviceID = try link.businessID
    #expect(workflow.state.summary == "已连接" && workflow.state.status(for: currentDeviceID) == "已连接")
    await link.releaseObservationEnd()
    await #expect(throws: NexArmError.disconnected) { try await action.value }
    #expect(workflow.state.phase == .connected && workflow.state.summary == "已连接")
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) func bluetoothNativeBlockingResetsWithoutBusinessTimeouts() {
    let now = ContinuousClock.now
    var budget = NexArmBLETrafficBudget(started: now)
    let blocked = budget.canSend(at: now, systemReady: false)
    #expect(!blocked)
    #expect(!budget.isSendBlocked(at: now.advanced(by: .milliseconds(1999))))
    #expect(budget.isSendBlocked(at: now.advanced(by: .seconds(2))))
    budget.cancelBlockedWrite()
    #expect(!budget.isSendBlocked(at: now.advanced(by: .seconds(3))))
    let blockedAgain = budget.canSend(at: now.advanced(by: .seconds(4)), systemReady: false)
    #expect(!blockedAgain)
    budget.resumed()
    #expect(!budget.isSendBlocked(at: now.advanced(by: .seconds(8))))
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothBusinessRejectionDoesNotRecordOrRecoverAndManualBypassesResources() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let reports = ActionReportStore()
    try await workflow.performGesture(.nod, repetitions: 1, recordReport: { try await reports.record($0) })
    #expect(await reports.snapshot() != nil)
    let rejectedReports = ActionReportStore()
    await #expect(throws: NexArmExecutionError.invalidArguments) {
        try await workflow.performGesture(.nod, repetitions: 0, recordReport: { try await rejectedReports.record($0) })
    }
    #expect(await rejectedReports.snapshot() == nil)
    workflow.withMotorResources = { _, _ in throw NexArmExecutionError.resourceBusy }
    await #expect(throws: NexArmExecutionError.resourceBusy) {
        try await workflow.resetArm(recordReport: { try await rejectedReports.record($0) })
    }
    #expect(await rejectedReports.snapshot() == nil)
    #expect(workflow.state.transportIssue == nil)
    #expect(workflow.state.error == nil && workflow.state.canControl)
    #expect(await link.connects == 1)
    // Manual completion failure is ignored, while a subsequent target is still sent.
    await link.disableTelemetry()
    workflow.tryAction(.nod)
    await workflow.waitUntilIdle()
    #expect(workflow.state.error == nil && workflow.state.transportIssue == nil)
    let sent = await link.observedCommands.count
    #expect(sent > 0)
    await link.resumeTelemetry()
    workflow.tryAction(.reset)
    await workflow.waitUntilIdle()
    #expect(await link.observedCommands.count > sent)
    #expect(workflow.state.error == nil && workflow.state.canControl)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothLateAimExecutionFailureIsIndependentOfDeviceRecordsAndCompletedTool() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let activity = ActionActivityWorkflow(state: ActionActivityState())
    let diagnosticFixture = try RuntimeFailurePresentationFixture(activity: activity)
    try await diagnosticFixture.start(activity: activity)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    try await workflow.aim(base: -0.8, pitch: 0.5) { message in
        await activity.recordFailure(title: "NexArm.Tracking.aim", source: "Fixture", message: message.message)
    }
    try await until { await !link.liveCommands.isEmpty }
    await link.failLiveValidationOnce()
    // A held target does not send again; the next target exercises the worker's late failure path.
    try await workflow.aim(base: -0.6, pitch: 0.5)
    try await until { activity.state.backgroundIssues.count == 1 }
    await workflow.waitUntilIdle()
    #expect(activity.state.backgroundIssues.first?.message == "invalidMotion")
    #expect(activity.state.items.isEmpty)
    #expect(workflow.state.error == nil && workflow.state.transportIssue == nil && workflow.state.canControl)
    #expect(await link.connects == 1)
    try await workflow.aim(base: 0.8, pitch: -0.5)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
    await diagnosticFixture.stop(activity: activity)
}

/// A rejected concurrent call cannot clear or borrow the running invocation's report.
@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothInvocationReportsAreIndependentDuringNativeRecovery() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    try await link.pushPosition()
    try await until(context: "passive seed") { workflow.state.joints.count == 6 }
    await link.holdTelemetry()
    let runningReports = ActionReportStore()
    let rejectedReports = ActionReportStore()
    let action = Task {
        try await workflow.shakeBase(cycles: 1, recordReport: { try await runningReports.record($0) })
    }
    try await until(context: "running Action first packet") { await !link.observedCommands.isEmpty }
    await #expect(throws: NexArmExecutionError.busy) {
        try await workflow.resetArm(recordReport: { try await rejectedReports.record($0) })
    }
    #expect(await rejectedReports.snapshot() == nil)
    await link.loseConnection()
    await #expect(throws: NexArmError.disconnected) { try await action.value }
    let report = await runningReports.snapshot()
    #expect(report?.hasFailures == true)
    #expect(report?.failureDescription == "disconnected")
    #expect(await rejectedReports.snapshot() == nil)
    try await until(context: "native reconnect") { await link.connects == 2 && workflow.state.phase == .connected }
    #expect(workflow.state.error == nil)
    #expect(workflow.state.transportIssue == nil)
    #expect(workflow.state.transportIssue == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) func bluetoothProtocolFailuresAreNotNativeSystemErrorsOrExecutionTimeouts() {
    let invalid = NexArmBluetoothFailure(step: .response, error: NexArmError.invalidPacket)
    let overflow = NexArmBluetoothFailure(step: .response, error: NexArmError.overflow)
    #expect(invalid == .protocolViolation(.invalidPacket))
    #expect(overflow == .protocolViolation(.receiveOverflow))
    #expect(BluetoothPresentation.failure(invalid) == "蓝牙回包格式无效")
    #expect(BluetoothPresentation.failure(overflow) == "蓝牙接收数据超过缓冲上限")
    #expect(NexArmBluetoothFailure(step: .response, error: NexArmError.timeout) == .timeout(.response))
}

@Test(.actionCatalog) func bluetoothObservationAdmissionFailurePreservesDependencyClassification() async throws {
    let link = BluetoothArmFixture()
    try await link.connect(link.id)
    await link.rejectObservation(.busy)
    let controller = NexArmActionController(link: link, compatibilityPolicy: .passiveBLE)
    let packet = try NexArmMotorCommands.move(motor: 5, target: 2100, options: .init(speed: 200, acceleration: 30))
    let plan = try NexArmMotionPlan(lockedMotors: [5], frames: [.init(packet: packet, milliseconds: 1000)])
    await #expect(throws: NexArmError.busy) { try await controller.performPlan(plan, completion: .init()) }
    #expect(await controller.motorResults.allSatisfy { $0.failure == .admissionFailed && !$0.started })
    #expect(await !controller.motorResults.isEmpty)
    #expect(await link.status().failure == nil)
    #expect(await link.status().phase == .connected)
    await link.close()
}

/// Execution observation survives a connection-generation change without touching replacement state.
@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothLateNativeAimErrorIsReportedAfterRecoveryFencesTheConnection() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let activity = ActionActivityWorkflow(state: ActionActivityState())
    let diagnosticFixture = try RuntimeFailurePresentationFixture(activity: activity)
    try await diagnosticFixture.start(activity: activity)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    let origin = NexArmControlOrigin(
        source: "Fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString,
        callID: UUID().uuidString)
    try await workflow.aim(base: -0.8, pitch: 0.5, origin: origin) { failure in
        await activity.recordFailure(
            title: "NexArm.Tracking.aim", source: failure.origin?.source ?? "", message: failure.message,
            failureCode: failure.code,
            context: .init(
                workerID: failure.workerID, sessionID: failure.origin?.sessionID,
                inputID: failure.origin?.inputID, callID: failure.origin?.callID))
    }
    await link.failLiveAfterNativeDisconnect()
    // Trigger a new write whether the first target was already admitted or is still pending.
    try await workflow.aim(base: -0.6, pitch: 0.5, origin: origin)
    try await until(context: "native failure before caller returns") { await link.waitingForLiveFailure }
    try await until(context: "recovery fences old generation") { workflow.state.recoveryStage == .cleaning }
    await link.releaseLiveFailure()
    try await until(context: "late execution failure reaches home") { activity.state.backgroundIssues.count == 1 }
    #expect(activity.state.backgroundIssues.first?.message == "timeout")
    #expect(activity.state.backgroundIssues.first?.context?.callID == origin.callID)
    #expect(activity.state.backgroundIssues.first?.context?.sessionID == origin.sessionID)
    #expect(activity.state.backgroundIssues.first?.context?.inputID == origin.inputID)
    #expect(activity.state.backgroundIssues.first?.context?.workerID != nil)
    try await until { await link.connects == 2 && workflow.state.phase == .connected }
    #expect(workflow.state.error == nil && workflow.state.canControl)
    #expect(workflow.state.transportIssue == nil)
    #expect(workflow.state.transportIssue == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
    await diagnosticFixture.stop(activity: activity)
}

@Test(.actionCatalog) func bluetoothFeedbackReadFailureDoesNotChangeNativeStateOrBecomeSendFailure() async throws {
    let link = BluetoothArmFixture()
    try await link.connect(link.id)
    await link.rejectObservationRead(.invalidPacket)
    let controller = NexArmActionController(link: link, compatibilityPolicy: .passiveBLE)
    let packet = try NexArmMotorCommands.move(motor: 5, target: 2100, options: .init(speed: 200, acceleration: 30))
    let plan = try NexArmMotionPlan(lockedMotors: [5], frames: [.init(packet: packet, milliseconds: 1000)])
    await #expect(throws: NexArmError.invalidPacket) { try await controller.performPlan(plan, completion: .init()) }
    #expect(await controller.motorResults.allSatisfy { $0.failure == .feedbackFailed && !$0.started })
    #expect(await link.observedCommands.isEmpty)
    #expect(await link.status().failure == nil)
    #expect(await link.status().phase == .connected)
    await link.close()
}

@Test(.actionCatalog) func bluetoothRecoveryRequiresKnownNativeEvidenceAndIgnoresBusinessErrors() {
    struct UnknownFailure: Error {}
    var snapshot = NexArmBluetoothSnapshot()
    snapshot.power = .poweredOn
    #expect(!BluetoothRecoveryPolicy.canRetry(UnknownFailure(), snapshot: snapshot))
    #expect(!BluetoothRecoveryPolicy.canRetry(NexArmExecutionError.feedbackTimeout, snapshot: snapshot))
    #expect(!BluetoothRecoveryPolicy.canRetry(NexArmError.busy, snapshot: snapshot))
    #expect(!BluetoothRecoveryPolicy.canRetry(NexArmError.sessionReplaced, snapshot: snapshot))
    #expect(BluetoothRecoveryPolicy.canRetry(NexArmError.timeout, snapshot: snapshot))
    #expect(!BluetoothRecoveryPolicy.canRetry(NexArmError.invalidPacket, snapshot: snapshot))
    snapshot.failure = .protocolViolation(.invalidPacket)
    #expect(BluetoothRecoveryPolicy.canRetry(NexArmError.invalidPacket, snapshot: snapshot))
    let system = NSError(domain: "NativeFixture", code: 17)
    #expect(!BluetoothRecoveryPolicy.canRetry(system, snapshot: snapshot))
    snapshot.failure = .native(step: .writing, domain: "NativeFixture", code: 17)
    #expect(BluetoothRecoveryPolicy.canRetry(system, snapshot: snapshot))
    #expect(!BluetoothRecoveryPolicy.canRetry(NSError(domain: "NativeFixture", code: 18), snapshot: snapshot))
    snapshot.power = .unauthorized
    #expect(!BluetoothRecoveryPolicy.canRetry(NexArmBluetoothError.unavailable, snapshot: snapshot))
}

@Test(.actionCatalog) func bluetoothWriteCapabilitySelectionAndAcknowledgmentWindowAreBounded() throws {
    #expect(
        try NexArmBLEWriteMode.select(withResponse: true, withoutResponse: false, preferred: .unacknowledged)
            == .acknowledged)
    #expect(
        try NexArmBLEWriteMode.select(withResponse: false, withoutResponse: true, preferred: .acknowledged)
            == .unacknowledged)
    #expect(
        try NexArmBLEWriteMode.select(withResponse: true, withoutResponse: true, preferred: .unacknowledged)
            == .unacknowledged)
    #expect(
        try NexArmBLEWriteMode.select(withResponse: true, withoutResponse: true, preferred: .acknowledged)
            == .acknowledged)
    #expect(throws: NexArmBluetoothError.incompatibleService) {
        try NexArmBLEWriteMode.select(withResponse: false, withoutResponse: false, preferred: .unacknowledged)
    }
    var window = NexArmBLEControlWriteWindow()
    let initialReservation = window.reserve()
    let first = try #require(initialReservation)
    let blockedReservation = window.reserve()
    #expect(blockedReservation == nil)
    #expect(window.token == first)
    window.complete()
    let nextReservation = window.reserve()
    #expect(try #require(nextReservation) != first)
}

@Test(.actionCatalog) func bluetoothSimpleActionsAndResetDoNotRequireUnavailableIKQueries() async throws {
    let link = BluetoothArmFixture()
    try await link.connect(link.id)
    await link.rejectIKQueries()
    let controller = NexArmActionController(link: link, compatibilityPolicy: .passiveBLE)
    for gesture in [NexArmGesture.nod, .shakeHead] { try await controller.performGesture(gesture, repetitions: 1) }
    try await controller.resetPosition()
    let reset = try #require(await link.observedCommands.last)
    #expect(reset.isSynchronousPositionWrite)
    #expect(reset.motorTargets == [1: 2048, 2: 2087, 3: 1198, 4: 1238, 5: 2048])
    for (motor, target) in [(3, 1198), (4, 1238)] {
        try await controller.resetMotor(id: motor, options: .init(), completion: .init())
        #expect(await link.observedCommands.last?.motorTargets == [motor: target])
    }
    #expect(await link.ikRequests.isEmpty)
    #expect(await !link.observedCommands.isEmpty)
    #expect(await link.status().failure == nil)
    #expect(await link.status().phase == .connected)
    await link.close()
}

@Test(.actionCatalog) func bluetoothOrdinaryResetIgnoresTrackingFeedbackAndPreparedIKHome() async throws {
    let link = BluetoothArmFixture()
    try await link.connect(link.id)
    let controller = NexArmActionController(link: link, compatibilityPolicy: .passiveBLE)
    let tracking = try NexArmJointCommand.positions(base: 0, pitch: 0)
    #expect(tracking == [2047, 2087, 1984, 2045, 2048])
    let feedback = try NexArmPacket(
        command: 11,
        payload: ([299, 0, 327, -19, 0, 0] + tracking + [1630]).flatMap {
            let bits = UInt16(bitPattern: Int16($0))
            return [UInt8(bits & 255), UInt8(bits >> 8)]
        })
    _ = try await controller.receivePassiveFeedback(feedback)
    _ = try await controller.manualPlan(gesture: .tiltLeft)  // Cache a different fixture IK home.
    let queries = await link.ikRequests.count
    await link.rejectIKQueries()
    let manual = try await controller.manualPlan(gesture: nil)
    #expect(manual.steps.count == 1 && manual.lockedMotors == Set(1...5))
    #expect(manual.steps[0].targets == [1: 2048, 2: 2087, 3: 1198, 4: 1238, 5: 2048])
    try await controller.resetPosition()
    #expect(await link.observedCommands.last?.motorTargets == manual.steps[0].targets)
    // An explicit single-motor software home still takes precedence, without firmware calibration.
    try await controller.configureMotorHome(id: 4, target: 1300)
    try await controller.resetMotor(id: 4, options: .init(), completion: .init())
    #expect(await link.observedCommands.last?.motorTargets == [4: 1300])
    #expect(await link.ikRequests.count == queries)
    await link.close()
}

@Test(.actionCatalog) func bluetoothRequestedRecipeDoesNotPrepareUnrelatedPresets() async throws {
    let link = BluetoothArmFixture()
    try await link.connect(link.id)
    let controller = NexArmActionController(link: link, compatibilityPolicy: .passiveBLE)
    _ = try await controller.manualPlan(gesture: .tiltLeft)
    let first = await link.ikRequests.count
    #expect(first == 2)  // Home and one requested pose, not every preset in the catalog.
    _ = try await controller.manualPlan(gesture: .tiltLeft)
    #expect(await link.ikRequests.count == first)
    _ = try await controller.manualPlan(gesture: .tiltRight)
    #expect(await link.ikRequests.count == first + 1)
    await link.close()
}

@Test(.actionCatalog) func bluetoothInterruptedQueryUsesOnlyTheCurrentNativeReason() {
    var snapshot = NexArmBluetoothSnapshot()
    snapshot.failure = .requestInterrupted(command: 7)
    let message = BluetoothPresentation.currentIssue(snapshot)
    #expect(message?.contains("0x07") == true)
    #expect(message?.contains("Action") == false)
    snapshot.failure = nil
    snapshot.feedbackHealthy = true
    #expect(BluetoothPresentation.currentIssue(snapshot) == nil)
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func bluetoothManualSimpleCommandsRemainUsableWithoutIKOrResourceAdmission() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await workflow.waitUntilIdle()
    workflow.connect(try link.businessID)
    await workflow.waitUntilIdle()
    await link.rejectIKQueries()
    workflow.withMotorResources = { _, _ in throw NexArmExecutionError.resourceBusy }
    for action in [BluetoothArmAction.nod, .shakeHead, .reset] {
        let before = await link.observedCommands.count
        workflow.tryAction(action)
        try await until { await link.observedCommands.count > before }
        await workflow.waitUntilIdle()
        #expect(workflow.state.canControl)
    }
    #expect(await link.observedCommands.last?.motorTargets == [1: 2048, 2: 2087, 3: 1198, 4: 1238, 5: 2048])
    #expect(await link.ikRequests.isEmpty)
    #expect(await link.connects == 1)
    #expect(workflow.state.transportIssue == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.actionCatalog) @MainActor func callableDeviceAdmissionRejectsBackgroundAndUnknownDeviceWithoutEffects()
    async throws
{
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    #expect(throws: DeviceControlError.unavailable) {
        try workflow.validateControlAdmission(.init(operation: .connect, id: UUID().uuidString))
    }
    workflow.setForeground(false)
    #expect(throws: NexArmExecutionError.background) {
        try workflow.validateControlAdmission(.init(operation: .scan))
    }
    #expect(await link.connects == 0)
    await workflow.waitUntilIdle()
    workflow.setForeground(true)
    try workflow.validateControlAdmission(.init(operation: .scan))
    workflow.disconnect()
    await workflow.waitUntilIdle()
}

@Test(.actionCatalog) @MainActor func bluetoothPresentationCannotAuthorizeNativeExecution() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    workflow.state.present(.phase(.connected))
    workflow.state.present(.availability(.available))
    #expect(workflow.state.canControl)
    #expect(workflow.service.state.phase == .idle)
    #expect(throws: NexArmExecutionError.controlNotReady) {
        try workflow.validateControlAdmission(.init(operation: .preset, action: "nod"))
    }
    #expect(await link.observedCommands.isEmpty)
    try await workflow.shutdown()
    #expect(workflow.state.phase == .idle)
}

@Test(.actionCatalog) @MainActor func robotPublicFactsFollowNativeConnectionAndImmediateSafetyInvalidation()
    async throws
{
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let storage = StateContainer()
    let scope = try storage.makeScope()
    try workflow.service.connectPublicState(scope: scope)
    let reader = try storage.contextReader(scope: scope)
    #expect(try reader.snapshot(names: ["robot"]).json.contains("unknown"))
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(try link.businessID)
    try await until { workflow.trackingAvailable }
    let connected = try reader.snapshot(names: ["robot"]).json
    #expect(connected.contains("\"connected\":true") && connected.contains("\"controlAvailable\":true"))
    workflow.setForeground(false)
    #expect(try reader.snapshot(names: ["robot"]).json.contains("\"controlAvailable\":false"))
    try await workflow.shutdown()
    #expect(try reader.snapshot(names: ["robot"]).json.contains("\"connected\":false"))
    observer.cancel()
    await observer.value
    scope.close()
    #expect(throws: StateError.closed) { try reader.snapshot(names: ["robot"]) }
}
