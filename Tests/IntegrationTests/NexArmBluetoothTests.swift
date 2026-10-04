import ActionRuntime
import Actions
import AgentCore
import AppWorkflows
import Foundation
import Gateway
import Storage
import Testing
import UI

@testable import PlatformKit

/// Explicit simulation. Default tests never create a CoreBluetooth manager or move physical hardware.
private actor BluetoothArmFixture: NexArmBluetoothLink {
    var ik = NexArmTestIK()
    private(set) var observedCommands: [NexArmPacket] = []
    var observation: UUID?
    var telemetry = NexArmTelemetryCache()
    var lastPush = ContinuousClock.now.advanced(by: .seconds(-1))
    func beginObservation() throws -> UUID {
        guard snapshot.feedbackHealthy else { throw NexArmError.feedbackLost }
        liveSession = nil
        let token = UUID()
        observation = token
        return token
    }
    func endObservation(_ session: UUID) { if observation == session { observation = nil } }
    func sendObserved(_ packet: NexArmPacket, session: UUID) throws -> Bool {
        guard observation == session else { throw CancellationError() }
        guard !liveBlocked else { return false }
        observedCommands.append(packet)
        try write(packet)
        return true
    }
    func latestObservation(after sequence: UInt64, session: UUID) async throws -> NexArmTelemetry? {
        guard observation == session else { throw CancellationError() }
        guard snapshot.feedbackHealthy else { throw NexArmError.feedbackLost }
        if !telemetryUnavailable, !holdPose, ContinuousClock.now - lastPush >= .milliseconds(100) {
            let packet = try await exchange(NexArmPacket(command: 11), replyID: 255, replyCommand: 11, replyCount: 24)
            try telemetry.receive(packet.bytes)
            lastPush = .now
        }
        guard let value = telemetry.latest, value.sequence > sequence else { return nil }
        return value
    }
    func health(_ healthy: Bool) {
        snapshot.feedbackHealthy = healthy
        emit.yield(snapshot)
    }
    nonisolated let updates: AsyncStream<NexArmBluetoothSnapshot>
    private let emit: AsyncStream<NexArmBluetoothSnapshot>.Continuation
    nonisolated let id = UUID()
    var snapshot = NexArmBluetoothSnapshot()
    var dropPositionReplies = false
    func dropPositions() { dropPositionReplies = true }
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
    var liveSession: UUID?
    var liveBlocked = false
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
    func blockLive(_ value: Bool) { liveBlocked = value }
    func disableTelemetry() { telemetryUnavailable = true }
    func beginLiveControl() throws -> UUID {
        guard snapshot.phase == .connected else { throw NexArmError.disconnected }
        observation = nil
        let id = UUID()
        liveSession = id
        pendingPose?.resume(throwing: CancellationError())
        pendingPose = nil
        return id
    }
    func sendLive(_ packet: NexArmPacket, session: UUID) throws -> Bool {
        guard liveSession == session, snapshot.phase == .connected else { throw NexArmError.disconnected }
        guard !liveBlocked else { return false }
        if limitLiveRate, let lastLiveWrite, ContinuousClock.now - lastLiveWrite < .milliseconds(50) { return false }
        lastLiveWrite = .now
        liveCommands.append(packet)
        // Unacknowledged command admission is recorded separately; no fake feedback completion.
        if packet.command == 3 {
            let index = Int(packet.id) - 1
            let target = Int(packet.payload[2]) | Int(packet.payload[3]) << 8
            if index == 4 { wrist = target } else { motorOverrides[index] = target }
        }
        return true
    }
    func endLiveControl(_ session: UUID) { if liveSession == session { liveSession = nil } }
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
    func connect(_ id: UUID) async throws {
        guard id == self.id else { throw NexArmBluetoothError.unknownDevice }
        connects += 1
        snapshot.selected = .init(id: id, name: displayName, rssi: -45)
        snapshot.failure = nil
        snapshot.phase = .connecting
        emit.yield(snapshot)
        if holdConnection { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        if incompatibleService { throw NexArmBluetoothError.incompatibleService }
        snapshot.phase = .connected
        emit.yield(snapshot)
    }
    func disconnect() {
        disconnects += 1
        snapshot.phase = .disconnected
        snapshot.scanning = false
        emit.yield(snapshot)
    }
    func close() { disconnect() }
    func write(_ packet: NexArmPacket) throws {
        guard liveSession == nil else { throw CancellationError() }
        guard snapshot.phase == .connected else { throw NexArmError.disconnected }
        if packet.command == 3, let targets = packet.motorTargets {
            let indicating = feedbackCommands.count < 4 && packet.id == 5
            if indicating { feedbackCommands.append(packet) } else { writes += 1 }
            if (indicating && loseLinkOnFeedback) || (!indicating && loseLinkOnMotion) {
                loseLinkOnFeedback = false
                loseLinkOnMotion = false
                loseConnection()
                throw NexArmError.timeout
            }
            if failMotion || failFeedback { throw NexArmError.timeout }
            for (id, target) in targets {
                if id == 5 { wrist = target } else { motorOverrides[id - 1] = target }
            }
            return
        }
        if packet.isSynchronousPositionWrite {
            let intent = try ik.intent(packet)
            let isReset = intent.payload[6] == 200 && (feedbackCommands.isEmpty || resetHeight != 197)
            if isReset {
                feedbackCommands.append(packet)
                if loseLinkOnFeedback {
                    loseLinkOnFeedback = false
                    loseConnection()
                    throw NexArmError.timeout
                }
            }
            if !isReset { writes += 1 }
            if loseLinkOnMotion {
                loseLinkOnMotion = false
                loseConnection()
                throw NexArmError.timeout
            }
            if failMotion || failFeedback { throw NexArmError.timeout }
            let p = intent.payload
            let target = stride(from: 0, to: 12, by: 2).map {
                Int(Int16(bitPattern: UInt16(p[$0]) | UInt16(p[$0 + 1]) << 8))
            }
            x = target[1]
            y = target[2]
            z = isReset ? resetHeight : target[3]
            pitch = target[0]
            roll = target[4]
            // Arm motion preserves independently measured claw state.
            for (id, target) in packet.motorTargets ?? [:] {
                if id == 5 { wrist = target } else { motorOverrides[id - 1] = target }
            }
            return
        }
        feedbackCommands.append(packet)
        if loseLinkOnFeedback {
            loseLinkOnFeedback = false
            loseConnection()
            throw NexArmError.timeout
        }
        if failFeedback { throw NexArmError.timeout }
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
        guard liveSession == nil else { throw CancellationError() }
        guard snapshot.phase == .connected else { throw NexArmError.disconnected }
        if packet.command == 11, dropPositionReplies {
            snapshot.feedbackHealthy = false
            throw NexArmError.timeout
        }
        if packet.command == 7 { return try ik.reply(packet) }
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
            guard liveSession == nil else { throw CancellationError() }
            writes += 1
            if loseLinkOnMotion {
                loseLinkOnMotion = false
                loseConnection()
                throw NexArmError.timeout
            }
            if failMotion { throw NexArmError.timeout }
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
        state: BluetoothSettingsState(), link: link, quiesce: {},
        makeStore: { try LocalDocumentStore<BluetoothDeviceRecord>(url: file, maximumBytes: 4096) })
}
@MainActor
private func until(attempts: Int = 250, _ predicate: @MainActor () async -> Bool) async throws {
    for _ in 0..<attempts {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for a controlled test event")
    throw NexArmError.timeout
}
private func bluetoothTestFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("bluetooth-tests-\(UUID()).json")
}

@Test func bluetoothReplyRequiresACKAndMatchingReassembledPacket() throws {
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

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothSettingsConnectionPersistsAcrossNavigationAndAssistantExecutes() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .connected)
    #expect(workflow.state.remembered?.id == link.id)
    #expect(await link.feedbackCommands.map(\.command) == [3, 3, 3, 3])
    #expect(
        await link.feedbackCommands.dropFirst().map { Int($0.payload[2]) | Int($0.payload[3]) << 8 } == [
            1957, 2139, 2048,
        ])
    workflow.openPage()
    await workflow.waitUntilIdle()
    #expect(await link.feedbackCommands.count == 4)
    workflow.closePage()
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .connected)
    #expect(await link.disconnects == 0)
    try await runNexArmAssistantAction(cycles: 1) { try await workflow.shakeBase(cycles: $0) }
    #expect(await link.writes == 5)
    #expect(workflow.state.motionStatus == "已完成左右晃动 1 次并回位")
    workflow.disconnect()
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .idle)
    #expect(workflow.state.remembered?.id == link.id)
    await #expect(throws: BluetoothWorkflowError.self) { try await workflow.shakeBase(cycles: 1) }
    observer.cancel()
    await observer.value
    let restored = bluetoothTestWorkflow(BluetoothArmFixture(), file: file)
    let restoreObserver = Task { await restored.run() }
    try await until { restored.state.remembered?.id == link.id }
    restored.forget()
    await restored.waitUntilIdle()
    #expect(restored.state.remembered == nil)
    let saved = try await LocalDocumentStore<BluetoothDeviceRecord>(url: file).load()
    #expect(saved?.value.id == nil)
    restoreObserver.cancel()
    await restoreObserver.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothRejectsIncompatibleServiceAndCancelsConnectingOnBackground() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    await link.configure(wrong: true)
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .failed)
    #expect(workflow.state.remembered == nil)
    await #expect(throws: BluetoothWorkflowError.self) { try await workflow.shakeBase(cycles: 1) }
    #expect(await link.writes == 0)
    await link.configure(hold: true)
    workflow.connect(link.id)
    try await until { await link.status().phase == .connecting }
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .idle)
    await #expect(throws: BluetoothWorkflowError.self) { try await workflow.shakeBase(cycles: 1) }
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothBackgroundJoinsCommittedLegAndDoesNotResumeMotion() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    let movement = Task { try await workflow.shakeBase(cycles: 3) }
    try await until { await link.writes == 1 }
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    await #expect(throws: CancellationError.self) { try await movement.value }
    #expect(await link.writes == 1)
    #expect(workflow.state.phase == .idle && !workflow.state.executing)
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(await link.writes == 1)
    #expect(workflow.state.phase == .connected)
    #expect(await link.feedbackCommands.count == 4)
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothUnknownMotionKeepsConnectionAndRecoversWithoutReplay() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    await link.configure(fail: true)
    await #expect(throws: BluetoothWorkflowError.self) { try await workflow.shakeBase(cycles: 1) }
    #expect(workflow.state.phase == .connected && workflow.state.canControl)
    #expect(await link.writes == 5)
    #expect(workflow.state.motionStatus == "动作未确认完成")
    await link.configure()
    await workflow.refreshDevice()
    #expect(workflow.state.error == nil)
    #expect(await link.writes == 5)
    try await workflow.shakeBase(cycles: 1)
    #expect(await link.writes == 10)
    #expect(await link.connects == 1)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothConnectionWaitsForPreviousConversationCleanup() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    var gate: CheckedContinuation<Void, Never>?
    var calls = 0
    let workflow = BluetoothWorkflow(
        state: BluetoothSettingsState(), link: link,
        quiesce: {
            calls += 1
            if calls == 1 { await withCheckedContinuation { gate = $0 } }
        }, makeStore: { try LocalDocumentStore<BluetoothDeviceRecord>(url: file, maximumBytes: 4096) })
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    try await until { gate != nil }
    #expect(await link.status().phase == .disconnected)
    #expect(workflow.state.phase == .connecting)
    gate?.resume()
    gate = nil
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .connected)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    #expect(calls == 1)
    observer.cancel()
    await observer.value
}

@Test @MainActor func bluetoothDisconnectDoesNotQuiesceUnrelatedVoiceSession() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    var barriers = 0
    let workflow = BluetoothWorkflow(
        state: BluetoothSettingsState(), link: link, quiesce: { barriers += 1 },
        makeStore: { try LocalDocumentStore<BluetoothDeviceRecord>(url: file, maximumBytes: 4096) })
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    #expect(barriers == 0)
    workflow.setForeground(true)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    #expect(barriers == 1)
    #expect(workflow.state.phase == .connected)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    #expect(barriers == 1)
    observer.cancel()
    await observer.value
    #expect(barriers == 1)
}

@Test func bluetoothFailureIdentifiesNativeStep() {
    #expect(BluetoothPresentation.failure(.timeout(.connecting)) == "建立蓝牙连接超时")
    #expect(BluetoothPresentation.failure(.timeout(.notifications)) == "开启设备通知超时")
    #expect(BluetoothPresentation.failure(.timeout(.response)) == "等待设备回复超时")
    let native = NexArmBluetoothFailure(step: .writing, error: NSError(domain: "fixture.transport", code: 42))
    #expect(native == .native(step: .writing, domain: "fixture.transport", code: 42))
    #expect(BluetoothPresentation.failure(native) == "发送设备指令失败（fixture.transport 42）")
    #expect(BluetoothPresentation.failure(.incompatibleService(.services)) == "发现设备服务失败：蓝牙服务不兼容")
    #expect(BluetoothPresentation.failure(.disconnectUnconfirmed) == "蓝牙断开尚未确认，请关闭系统蓝牙后重试")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothPoseProtocolConnectsWithoutFirmwareQueriesAndAssistantExecutes() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.configure(missing: true)
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady)
    #expect(workflow.state.notice == "已连接，可以返回对话控制机械臂")
    #expect(await link.versionReads == 0)
    #expect(await link.feedbackCommands.map(\.command) == [3, 3, 3, 3])
    #expect(await link.writes == 0)
    workflow.openPage()
    workflow.closePage()
    await workflow.waitUntilIdle()
    #expect(await link.feedbackCommands.count == 4)
    try await runNexArmAssistantAction(cycles: 1) { try await workflow.shakeBase(cycles: $0) }
    #expect(await link.writes == 5)
    #expect(await link.versionReads == 0)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    #expect(!workflow.state.controlReady)
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothMissingVersionStillRejectsInvalidPoseBeforeAnyMotion() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.configure(missing: true)
    await link.invalidatePose()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    #expect(!workflow.state.controlReady)
    #expect(await link.feedbackCommands.isEmpty)
    #expect(await link.writes == 0)
    #expect(workflow.state.error?.contains("位置读取/协议检查") == true)
    #expect(workflow.state.error?.contains("设备坐标 [") == true)
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothBackgroundJoinsConnectionResetWithoutStartingWristOrDeclaringReady() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    try await until { await link.feedbackCommands.count == 1 }
    #expect(workflow.state.phase == .indicating && !workflow.state.controlReady)
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    #expect(await link.feedbackCommands.map(\.command) == [3])
    #expect(workflow.state.phase == .idle && !workflow.state.controlReady)
    #expect(await link.status().phase == .disconnected)
    observer.cancel()
    await observer.value
}

@Test func bluetoothWriteAcknowledgmentDoesNotMasqueradeAsPositionFeedback() throws {
    let outgoing = try NexArmPacket(command: 54, payload: [0xD0, 0x07])
    var reply = NexArmBLEReply(id: 255, command: 54, count: 0, acknowledgmentOnly: true, response: outgoing)
    try reply.receive(try NexArmPacket(command: 11, payload: Array(repeating: 0, count: 24)).bytes)
    #expect(reply.completed == nil)
    reply.acknowledged = true
    #expect(reply.completed == outgoing)  // Private ACK token, not public position data.
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothConnectionFeedbackFailureKeepsLinkAndDoesNotReplayGesture() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.configure(feedbackFailure: true)
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .connected && workflow.state.controlReady)
    #expect(workflow.state.motionStatus == "连接提示动作未确认完成")
    workflow.openPage()
    await workflow.waitUntilIdle()
    #expect(await link.feedbackCommands.map(\.command) == [3, 3, 3, 3])
    await link.configure()
    await workflow.refreshDevice()
    #expect(workflow.state.joints.count == 6)
    #expect(await link.feedbackCommands.map(\.command) == [3, 3, 3, 3])
    #expect(await link.writes == 0)
    #expect(await link.connects == 1)
    observer.cancel()
    await observer.value
}

@Test func nexArmStrictFirmwareAndBLEPosePoliciesRejectInvalidInputs() async throws {
    for version: [UInt8] in [[1, 0, 2, 1, 0, 3], [1, 0, 3, 0, 0, 0], [0, 0, 0, 0, 0, 0]] {
        let link = BluetoothArmFixture()
        await link.setVersion(version)
        try await link.connect(link.id)
        let controller = NexArmActionController(link: link)
        await #expect(throws: NexArmError.unsupportedFirmware) { try await controller.verifyCompatibility() }
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

@Test(.timeLimit(.minutes(1))) func bluetoothConnectionIndicationOwnsOnlyMotor5() async throws {
    let link = BluetoothArmFixture()
    try await link.connect(link.id)
    let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
    try await controller.indicateConnection()
    #expect(await link.feedbackCommands.count == 4)
    #expect(await link.feedbackCommands.allSatisfy { $0.id == 5 })
    #expect(await controller.latestState.pose[2] == 350)  // Connection indication never resets XYZ.
    await #expect(throws: NexArmActionError.alreadyUsed) { try await controller.indicateConnection() }
}

@Test func bluetoothDiscoveryPrioritizesNamesButKeepsRenamedAndOtherDevices() {
    let renamed = NexArmBluetoothDevice(id: UUID(), name: "桌上的手臂", rssi: -20)
    let other = NexArmBluetoothDevice(id: UUID(), name: "温度计", rssi: -30)
    let arm = NexArmBluetoothDevice(id: UUID(), name: "Nex_Arm", rssi: -80)
    let unnamed = NexArmBluetoothDevice(id: UUID(), name: "未命名设备", rssi: -60)
    let rows = [renamed, other, arm, unnamed].sorted(by: BluetoothPresentation.discoveryOrder)
    #expect(rows.map(\.id) == [arm.id, renamed.id, other.id, unnamed.id])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothRenamedDeviceResumesWithoutSettingsOrMovementAndManualDisconnectPersists() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.rename("桌上的手臂")
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    workflow.closePage()
    #expect(workflow.state.controlReady)
    #expect(await link.versionReads == 0)
    let commands = await link.feedbackCommands
    workflow.setForeground(false)
    // Return before background cleanup has completed; reconnect joins it.
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady)
    #expect(await link.connects == 2)
    #expect(await link.feedbackCommands == commands)
    #expect(await link.writes == 0)
    #expect(workflow.state.notice == "已自动恢复连接，可以继续控制机械臂")
    workflow.disconnect()
    await workflow.waitUntilIdle()
    workflow.setForeground(false)
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(await link.connects == 2)
    #expect(!workflow.state.controlReady)
    let saved = try await LocalDocumentStore<BluetoothDeviceRecord>(url: file).load()
    #expect(saved?.value.automaticallyReconnect == false)
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothColdStartRestoresPreviouslyVerifiedDeviceWithoutGesture() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let store = try LocalDocumentStore<BluetoothDeviceRecord>(url: file)
    _ = try await store.save(.init(id: link.id, name: "已改名机械臂", automaticallyReconnect: true), expecting: nil)
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

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothManualDisconnectDuringBackgroundCleanupDisablesPersistedRecovery() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
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
    let saved = try await LocalDocumentStore<BluetoothDeviceRecord>(url: file).load()
    #expect(saved?.value.automaticallyReconnect == false)
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothGestureBackgroundCancelsRemainingLegsAndNeverReplays() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    let movement = Task { try await workflow.performGesture(.wave, repetitions: 3) }
    try await until { await link.writes >= 1 }
    #expect(workflow.state.executing)
    await #expect(throws: BluetoothWorkflowError.busy) {
        try await workflow.performGesture(.celebrate, repetitions: 1)
    }
    workflow.setForeground(false)
    await workflow.waitUntilIdle()
    await #expect(throws: CancellationError.self) { try await movement.value }
    #expect(await link.feedbackCommands.count == 4)
    #expect(!workflow.state.executing)
    workflow.setForeground(true)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady)
    #expect(await link.feedbackCommands.count == 4)
    observer.cancel()
    await observer.value
}

@Test func bluetoothJogPlannerUsesSpeedCurveAndVendorJointLimits() throws {
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

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothAllSixJoysticksStreamWithoutTelemetryAndReleaseDoesNotReset() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
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

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothLiveBackpressureDoesNotAccumulateCommandsAndResetPreemptsPreset() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
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
    #expect(Int(last.payload[2]) | Int(last.payload[3]) << 8 < 2048)
    #expect(sent.allSatisfy { Int($0.payload[2]) | Int($0.payload[3]) << 8 <= 2050 })
    let action = Task { try await workflow.performGesture(.wave, repetitions: 3) }
    try await until { await link.writes >= 1 }
    let before = ContinuousClock.now
    workflow.tryAction(.reset)
    try await until { await link.observedCommands.contains { $0.isSynchronousPositionWrite } }
    #expect(ContinuousClock.now - before < .seconds(1))
    await workflow.waitUntilIdle()
    await #expect(throws: CancellationError.self) { try await action.value }
    #expect(await link.feedbackCommands.count == 4)
    #expect(workflow.state.motionStatus == "已完成整臂归位")
    #expect(workflow.state.error == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1)))
func bluetoothManualMotorUncertainWriteLatchesFailure() async throws {
    let link = BluetoothArmFixture()
    try await link.connect(link.id)
    await link.configure(feedbackFailure: true)
    let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
    await #expect(throws: NexArmActionError.uncertainMotion) {
        try await controller.performGesture(.wave, repetitions: 1)
    }
    await #expect(throws: NexArmActionError.uncertainMotion) { try await controller.resetPosition() }
    #expect(await link.observedCommands.count == 7)
    await link.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothJoysticksRemainAvailableAfterUnconfirmedPreset() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    await link.configure(feedbackFailure: true)
    await #expect(throws: BluetoothWorkflowError.unverified) {
        try await workflow.performGesture(.wave, repetitions: 1)
    }
    await link.disableTelemetry()
    let reads = await link.poseReads
    workflow.setMotorVelocity(id: 3, value: 0.75)
    try await until { await link.liveCommands.count >= 3 }
    workflow.stopMotorControl()
    await workflow.waitUntilIdle()
    #expect(await link.poseReads == reads)
    #expect(workflow.state.controlReady && workflow.state.error == nil)
    #expect(await link.connects == 1)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1)))
func bluetoothRecoveryRequiresStationaryFeedbackAndSendsNoCommands() async throws {
    let link = BluetoothArmFixture()
    try await link.connect(link.id)
    let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
    await link.configure(feedbackFailure: true)
    await #expect(throws: NexArmActionError.uncertainMotion) {
        try await controller.performGesture(.wave, repetitions: 1)
    }
    let beforeRecovery = await link.writes
    await link.configure()
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

@Test func bluetoothDiscoverySeparatesDeviceNamesFromPresentationPolicy() {
    #expect(BluetoothPresentation.deviceName("未命名设备") == nil)
    #expect(NexArmBluetoothDevice.discoveryName(advertised: nil, cached: nil) == nil)
    #expect(NexArmBluetoothDevice.discoveryName(advertised: "  \n", cached: "未命名设备") == "未命名设备")
    #expect(NexArmBluetoothDevice.discoveryName(advertised: "", cached: " NexArm ") == "NexArm")
    #expect(NexArmBluetoothDevice.discoveryName(advertised: "桌上的机械臂", cached: "旧名字") == "桌上的机械臂")
}

@Test(.timeLimit(.minutes(1))) @MainActor
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
        .init(id: UUID(), name: "未命名设备", rssi: -20),
        .init(id: UUID(), name: " ", rssi: -20),
        .init(id: UUID(), name: "温度计", rssi: -20),
    ]
    await link.simulateDiscovery(rows)
    try await until { workflow.state.nearby.count == 2 }
    workflow.connect(link.id)
    #expect(workflow.state.nearby.isEmpty && !workflow.state.scanning)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady)
    let connected = await link.status()
    #expect(!connected.scanning && connected.devices.isEmpty)
    workflow.state.error = "旧错误"
    workflow.forget()
    await workflow.waitUntilIdle()
    #expect(workflow.state.remembered == nil && workflow.state.selected == nil)
    #expect(workflow.state.error == nil && workflow.state.motionStatus == nil)
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

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothTransportLossRecoversOnceWithoutMotionReplay() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    await link.loseConnectionOnNextMotion()
    await #expect(throws: (any Error).self) { try await workflow.shakeBase(cycles: 3) }
    try await until { await link.connects == 2 && workflow.state.controlReady }
    await workflow.waitUntilIdle()
    #expect(await link.writes == 1)
    #expect(await link.feedbackCommands.count == 4)
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

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothConnectionGestureTransportTimeoutRecoversWithoutRepeatingReset() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.loseConnectionOnNextFeedback()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    #expect(workflow.state.controlReady)
    #expect(workflow.state.error == nil)
    #expect(await link.connects == 2)
    #expect(await link.feedbackCommands.map(\.command) == [3])
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothResetRetiresPendingObservationWithoutClosingLiveControls() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
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

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothResetWithoutCompletionReplyDoesNotBlockNextPresetAndPreservesFailureDetail() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    await link.configure(feedbackFailure: true)
    await #expect(throws: BluetoothWorkflowError.unverified) {
        try await workflow.performGesture(.wave, repetitions: 1)
    }
    #expect(workflow.state.error == "动作指令未能发送，可直接再试其他动作或重置")
    await link.configure()
    workflow.tryAction(.reset)  // The fixture emits no reset completion response.
    await workflow.waitUntilIdle()
    #expect(await link.observedCommands.contains { $0.isSynchronousPositionWrite })
    #expect(workflow.state.controlReady)
    try await workflow.performGesture(.wave, repetitions: 1)
    #expect(workflow.state.error == nil)
    #expect(workflow.state.motionStatus == "已完成挥手并回位")
    #expect(await link.connects == 1)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test func aimFollowApproachesTheLatestCountWithoutJumpingThere() throws {
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
    #expect(throws: NexArmError.invalidMotion) { try planner.approach(id: 6, target: goal) }
}

@Test func aimFollowBrakesBeforeReversing() throws {
    var planner = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
    let start = Int(planner.targets[0])
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

@Test func aimReachMotorsStayBelowTheirSlowerSpeedLimit() throws {
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
    #expect(throws: NexArmError.invalidMotion) {
        try planner.approach(id: 2, target: start - 300, speedLimit: NexArmJogPlanner.maximumSpeed + 1)
    }
}

@Test func bluetoothJogShapesVelocityAndRejectsConfigurationWrites() throws {
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

@Test func bluetoothJogStickExtentControlsCruiseSpeedAndStallsDoNotCatchUp() throws {
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

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothNewPresetIgnoresPreviousFailureAndMissingOldFeedback() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    await link.configure(fail: true)
    await #expect(throws: BluetoothWorkflowError.unverified) {
        try await workflow.performGesture(.wave, repetitions: 1)
    }
    let before = await link.writes
    await link.configure()
    await link.disableTelemetry()
    await #expect(throws: BluetoothWorkflowError.feedbackTimeout) {
        try await workflow.performGesture(.tiltLeft, repetitions: 1)
    }
    #expect(await link.writes < before + 3)
    #expect(!workflow.state.controlReady && !workflow.state.executing)
    #expect(await link.connects == 1)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothSettingsSharesObservedExecutorAndPreemptsOldSequence() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    workflow.tryAction(.wave)
    try await until { await link.writes == 1 }
    workflow.tryAction(.tiltRight)
    await workflow.waitUntilIdle()
    #expect(await link.writes == 4)
    #expect(await link.liveCommands.isEmpty)
    #expect(workflow.state.error == nil && !workflow.state.testing)
    #expect(workflow.state.motionStatus == "已完成歪头并回位")
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothSettingsCongestionRetainsOnlyLatestTestAndResetCancelsEnding() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    await link.blockLive(true)
    workflow.tryAction(.dance)
    try await Task.sleep(for: .milliseconds(100))
    workflow.tryAction(.tiltLeft)
    await link.blockLive(false)
    try await until { await link.writes == 1 }
    workflow.tryAction(.reset)
    await workflow.waitUntilIdle()
    let commands = await link.observedCommands.filter { $0.isSynchronousPositionWrite }
    #expect(commands.count == 2)
    try await Task.sleep(for: .milliseconds(900))
    #expect(await link.observedCommands.filter { $0.isSynchronousPositionWrite } == commands)
    #expect(!workflow.state.testing && workflow.state.error == nil)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothFeedbackHealthDisablesIdleControlAndAbortsActionWithoutReplay() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    let before = await link.observedCommands.count
    await link.health(false)
    try await until { !workflow.state.controlReady }
    #expect(workflow.state.error?.contains("机械臂连接不稳定") == true)
    await link.health(true)
    await workflow.refreshDevice()
    try await until { workflow.state.controlReady }
    #expect(await link.observedCommands.count == before)
    let movement = Task { try await workflow.performGesture(.dance, repetitions: 1) }
    try await until { await link.observedCommands.count > before }
    await link.health(false)
    await #expect(throws: BluetoothWorkflowError.feedbackTimeout) { try await movement.value }
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

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothSettingsAndOwnedActionsShareResourceFenceWithoutReacquisition() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let resources = try nexArmTestResources()
    workflow.withMotorResources = { motors, operation in
        try await resources.run(
            resources: Set(motors.map { ResourceID(rawValue: "nexarm.motor.\($0)") }),
            owner: nil, lease: nil, operation: operation)
    }
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    workflow.tryAction(.nod)
    await workflow.waitUntilIdle()
    #expect(workflow.state.error == nil)
    try await resources.run(resources: [ResourceID(rawValue: "nexarm.motor.4")], owner: nil, lease: nil) {
        try await workflow.performGesture(.nod, repetitions: 1)
    }
    #expect(workflow.state.error == nil)
    #expect(workflow.lastActionReport?.entries.count == 6)
    #expect(workflow.lastActionReport?.entries.allSatisfy { $0.details["motor"] == "4" } == true)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test func bluetoothResponseTimeoutRetainsQueryAndSeparatesNotificationBytesFromPayload() {
    let missing = NexArmBluetoothFailure.responseTimeout(command: 11, expectedBytes: 24, receivedBytes: 0)
    #expect(BluetoothPresentation.failure(missing) == "读取机械臂位置回复超时（0x0B，期望载荷24字节，收到通知0字节）")
    let unmatched = NexArmBluetoothFailure.responseTimeout(command: 7, expectedBytes: 24, receivedBytes: 30)
    #expect(BluetoothPresentation.failure(unmatched) == "准备机械臂动作回复超时（0x07，期望载荷24字节，收到通知30字节）")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothPositionTimeoutKeepsLinkConnectedWithoutGrantingControlOrSendingMotion() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    await link.dropPositions()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    #expect(workflow.state.phase == .connected)
    #expect(!workflow.state.controlReady)
    #expect(workflow.state.status(for: link.id) == "已连接，控制未就绪")
    #expect(await link.disconnects == 0)
    await #expect(throws: BluetoothWorkflowError.controlNotReady) { try await workflow.aim(base: 0, pitch: 0) }
    #expect(await link.writes == 0)
    #expect(await link.feedbackCommands.isEmpty)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}

@Test func bluetoothSharedBudgetBoundsMixedProducerBurstsAndDoesNotCatchUp() {
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

@Test func bluetoothSystemBackpressurePreservesBudgetForTheNextAcceptedWrite() {
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

@Test func bluetoothDiagnosticsDistinguishNotificationTrafficFromValidFeedback() {
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

@Test(.timeLimit(.minutes(1))) @MainActor
func bluetoothAimSharesBackpressureFairlyAcrossAllFourMotors() async throws {
    let file = bluetoothTestFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let link = BluetoothArmFixture()
    let workflow = bluetoothTestWorkflow(link, file: file)
    let observer = Task { await workflow.run() }
    workflow.openPage()
    try await until { !workflow.state.nearby.isEmpty }
    workflow.connect(link.id)
    await workflow.waitUntilIdle()
    await link.throttleLive()
    try await workflow.aim(base: 0.6, pitch: 0.5)
    try await until { await link.liveCommands.count >= 20 }
    await workflow.stopActions()
    let commands = await link.liveCommands
    #expect(Set(commands.map(\.id)) == Set(UInt8(1)...UInt8(4)))
    #expect(commands.allSatisfy { $0.isLiveControl })
    #expect(workflow.state.controlReady)
    let count = commands.count
    try await Task.sleep(for: .milliseconds(100))
    #expect(await link.liveCommands.count == count)
    workflow.disconnect()
    await workflow.waitUntilIdle()
    observer.cancel()
    await observer.value
}
