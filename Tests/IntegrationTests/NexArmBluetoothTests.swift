import AppWorkflows
import Foundation
import Storage
import Testing
import UI

@testable import PlatformKit

/// Explicit simulation. Default tests never create a CoreBluetooth manager or move physical hardware.
private actor BluetoothArmFixture: NexArmBluetoothLink {
    nonisolated let updates: AsyncStream<NexArmBluetoothSnapshot>
    private let emit: AsyncStream<NexArmBluetoothSnapshot>.Continuation
    nonisolated let id = UUID()
    var snapshot = NexArmBluetoothSnapshot()
    var missingVersion = false
    var reportedVersion: [UInt8]?
    var driftingPose = false
    private(set) var connects = 0
    private(set) var versionReads = 0
    var wrongVersion = false
    var incompatibleService = false
    var displayName = "Nex_Arm"
    var holdConnection = false
    var failMotion = false
    var failFeedback = false
    var x = 270
    var y = 0
    var resetHeight = 197
    var z = 350
    var pitch = -180
    var claw = -35
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
    func connect(_ id: UUID) async throws {
        guard id == self.id else { throw NexArmBluetoothError.unknownDevice }
        connects += 1
        snapshot.selected = .init(id: id, name: displayName, rssi: -45)
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
        guard snapshot.phase == .connected else { throw NexArmError.disconnected }
        feedbackCommands.append(packet)
        if failFeedback { throw NexArmError.timeout }
        if packet.command == 54 {
            x = 200
            y = 0
            z = resetHeight
            pitch = -12
            claw = 0
            wrist = 2048
        } else if packet.command == 51 {
            guard packet.payload.count == 5, packet.payload[0] == 5 else { throw NexArmError.invalidPacket }
            wrist = Int(packet.payload[1]) | Int(packet.payload[2]) << 8
        } else {
            throw NexArmError.invalidPacket
        }
    }
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) throws -> NexArmPacket {
        guard snapshot.phase == .connected else { throw NexArmError.disconnected }
        if packet.command == 1 {
            versionReads += 1
            if let reportedVersion { return try NexArmPacket(command: 1, payload: reportedVersion) }
            if missingVersion { return try NexArmPacket(command: 1, payload: [1, 0, 2, 0, 0, 0]) }
            return try NexArmPacket(command: 1, payload: wrongVersion ? [9, 0, 0, 9, 0, 0] : [1, 0, 2, 1, 0, 2])
        }
        if packet.command == 0x32 {
            writes += 1
            if failMotion { throw NexArmError.timeout }
            let p = packet.payload
            #expect(Array(p[4..<12]) == Array(repeating: 0, count: 8))
            x += Int(Int16(bitPattern: UInt16(p[0]) | UInt16(p[1]) << 8))
            y += Int(Int16(bitPattern: UInt16(p[2]) | UInt16(p[3]) << 8))
        }
        if driftingPose { wrist += 10 }
        let base = 2048 - Int((atan2(Double(y), Double(x)) * 4096 / (2 * .pi)).rounded())
        let values = [x, y, z, pitch, 0, claw, base, 2048, 2048, 2048, wrist, 1647]
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
private func until(_ predicate: @MainActor () async -> Bool) async throws {
    for _ in 0..<250 {
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
    #expect(await link.feedbackCommands.map(\.command) == [54, 51, 51, 51])
    #expect(
        await link.feedbackCommands.dropFirst().map { Int($0.payload[1]) | Int($0.payload[2]) << 8 } == [
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
    #expect(await link.writes == 3)
    #expect(workflow.state.motionStatus == "已完成 1 次左右晃动并回位")
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
func bluetoothUnknownMotionFaultsConnectionAndNoAutomaticRetry() async throws {
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
    #expect(workflow.state.phase == .failed)
    await #expect(throws: BluetoothWorkflowError.self) { try await workflow.shakeBase(cycles: 1) }
    #expect(await link.writes == 1)
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
    #expect(NexArmBluetoothStep.connecting.failure(NexArmError.timeout) == "建立蓝牙连接超时，请重新连接")
    #expect(NexArmBluetoothStep.notifications.failure(NexArmError.timeout) == "开启设备通知超时，请重新连接")
    #expect(NexArmBluetoothStep.response.failure(NexArmError.timeout) == "等待设备回复超时，请重新连接")
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
    #expect(await link.feedbackCommands.map(\.command) == [54, 51, 51, 51])
    #expect(await link.writes == 0)
    workflow.openPage()
    workflow.closePage()
    await workflow.waitUntilIdle()
    #expect(await link.feedbackCommands.count == 4)
    try await runNexArmAssistantAction(cycles: 1) { try await workflow.shakeBase(cycles: $0) }
    #expect(await link.writes == 3)
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
    #expect(await link.feedbackCommands.map(\.command) == [54])
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
func bluetoothConnectionFeedbackFailureDoesNotRetryOrEnableActions() async throws {
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
    #expect(workflow.state.phase == .failed && !workflow.state.controlReady)
    #expect(workflow.state.motionStatus == "连接提示动作未完成")
    workflow.openPage()
    await workflow.waitUntilIdle()
    #expect(await link.feedbackCommands.map(\.command) == [54])
    await #expect(throws: BluetoothWorkflowError.disconnected) { try await workflow.shakeBase(cycles: 1) }
    #expect(await link.writes == 0)
    observer.cancel()
    await observer.value
}

@Test func nexArmStrictFirmwareAndBLEPosePoliciesRejectInvalidInputs() async throws {
    for version: [UInt8] in [[1, 0, 2, 1, 0, 3], [1, 0, 3, 0, 0, 0], [0, 0, 0, 0, 0, 0]] {
        let link = BluetoothArmFixture()
        await link.setVersion(version)
        try await link.connect(link.id)
        let controller = NexArmController(link: link)
        await #expect(throws: NexArmError.unsupportedFirmware) { try await controller.verifyCompatibility() }
        #expect(await link.versionReads == 1)
        #expect(await link.feedbackCommands.isEmpty)
        await link.close()
    }
    let moving = BluetoothArmFixture()
    await moving.configure(missing: true)
    await moving.setDriftingPose()
    try await moving.connect(moving.id)
    let controller = NexArmController(link: moving, compatibilityPolicy: .nexArmBLEProtocol)
    await #expect(throws: NexArmError.moving) { try await controller.verifyCompatibility() }
    #expect(await moving.feedbackCommands.isEmpty)
    await moving.close()
}

@Test(.timeLimit(.minutes(1))) func bluetoothResetOutsideHomeToleranceStopsBeforeID5() async throws {
    let link = BluetoothArmFixture()
    await link.setResetHeight(190)
    try await link.connect(link.id)
    let controller = NexArmController(link: link)
    await #expect(throws: NexArmError.uncertainMotion) { try await controller.indicateConnection() }
    await #expect(throws: NexArmError.uncertainMotion) { try await controller.indicateConnection() }
    #expect(await link.feedbackCommands.map(\.command) == [54])
    await link.close()
}

@Test func bluetoothDiscoveryPrioritizesNamesButKeepsRenamedAndOtherDevices() {
    let renamed = NexArmBluetoothDevice(id: UUID(), name: "桌上的手臂", rssi: -20)
    let other = NexArmBluetoothDevice(id: UUID(), name: "温度计", rssi: -30)
    let arm = NexArmBluetoothDevice(id: UUID(), name: "Nex_Arm", rssi: -80)
    let unnamed = NexArmBluetoothDevice(id: UUID(), name: "未命名设备", rssi: -60)
    let rows = [renamed, other, arm, unnamed].sorted(by: NexArmBluetoothDevice.discoveryOrder)
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
