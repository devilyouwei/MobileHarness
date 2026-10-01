import AgentCore
import Foundation
import PlatformKit
import Storage
import UI

#if os(iOS)
    import UIKit
#endif

public struct BluetoothDeviceRecord: Codable, Sendable {
    public let id: UUID?
    public let name: String?
    public let automaticallyReconnect: Bool?
    public init(id: UUID?, name: String?, automaticallyReconnect: Bool? = nil) {
        self.id = id
        self.name = name
        self.automaticallyReconnect = automaticallyReconnect
    }
}
public enum BluetoothWorkflowError: LocalizedError, Sendable, Equatable, ActionExecutionFailureProviding {
    case disconnected, busy, background, posture, unverified, controlNotReady, feedbackTimeout, completionTimeout
    public var actionExecutionFailure: ActionExecutionRecord.Failure {
        switch self {
        case .disconnected: .disconnected
        case .busy: .busy
        case .background: .background
        case .posture: .invalidPose
        case .unverified: .unconfirmed
        case .controlNotReady: .controlNotReady
        case .feedbackTimeout: .feedbackTimeout
        case .completionTimeout: .completionTimeout
        }
    }
    public var errorDescription: String? {
        switch self {
        case .disconnected: "机械臂未连接，请到设置 → 蓝牙外设连接 NexArm"
        case .busy: "机械臂正在处理上一项操作，请稍后重试"
        case .background: "请保持应用在前台后再控制机械臂"
        case .posture: "当前姿态不适合这个动作，请先调整机械臂姿态后重试"
        case .unverified: "动作未确认完成，可刷新状态或继续操作"
        case .feedbackTimeout: "动作反馈超时，结果未知"
        case .completionTimeout: "动作未在期限内到位"
        case .controlNotReady: "蓝牙已连接，但控制尚未就绪，请到设置 → 蓝牙外设重新验证"
        }
    }
}

/// Root-owned Bluetooth settings and action binding. No page owns the connection or motion task.
@MainActor
public final class BluetoothWorkflow: BluetoothControlling {
    public let state: BluetoothSettingsState
    private let link: any NexArmBluetoothLink
    private let quiesce: @MainActor () async -> Void
    private let makeStore: @Sendable () throws -> LocalDocumentStore<BluetoothDeviceRecord>
    private var store: LocalDocumentStore<BluetoothDeviceRecord>?
    private var revision: UUID?
    private var restoration: Task<Void, any Error>?
    private var controller: NexArmController?
    private var operation: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var motion: Task<Void, any Error>?
    private var liveTask: Task<Void, Never>?
    private var motorInputs = Array(repeating: 0.0, count: 6)
    private var armPlan: NexArmArmPlan?
    private var jogPlanner: NexArmJogPlanner?
    private var resetRequested = false
    private var controlRevision = UUID()
    private var testFrames: [NexArmGesture.TestFrame] = []
    private var testID = UUID()
    private var testDue = ContinuousClock.now
    private var testLabel = ""
    private var motionID: UUID?
    private var generation = UUID()
    private var foreground = true
    private var observing = false
    private var pageVisible = false
    private var scanWanted = false
    private var discoveryVisible = false
    private var discovery: Task<Void, Never>?
    private var forgetRequested = false
    private var reconnectEnabled = false
    private var manualDisconnectPending = false
    private var recoverOnDisconnect = false
    private var recoveryAttempted = false
    private var recovery: Task<Void, Never>?

    public init(
        state: BluetoothSettingsState, link: any NexArmBluetoothLink,
        quiesce: @escaping @MainActor () async -> Void,
        makeStore: @escaping @Sendable () throws -> LocalDocumentStore<BluetoothDeviceRecord>
    ) {
        self.state = state
        self.link = link
        self.quiesce = quiesce
        self.makeStore = makeStore
    }
    public func run() async {
        guard !observing else { return }
        observing = true
        defer { observing = false }
        do { try await restore() } catch { state.error = "设备记录读取失败：\(error.localizedDescription)" }
        scheduleReconnect()
        for await value in link.updates {
            if Task.isCancelled { break }
            apply(value)
        }
        disconnect(preserveReconnect: true)
        await waitUntilIdle()
    }
    private func restore() async throws {
        if store != nil { return }
        if let restoration {
            try await restoration.value
            return
        }
        let task = Task {
            let document = try makeStore()
            let saved = try await document.load()
            if let record = saved?.value {
                guard (record.id == nil) == (record.name == nil), (record.name?.utf8.count ?? 0) <= 256 else {
                    throw DocumentStorageError.invalidFile
                }
                if let id = record.id, let name = record.name {
                    state.remembered = .init(id: id, name: name)
                    reconnectEnabled = record.automaticallyReconnect ?? true
                }
            }
            revision = saved?.revision
            store = document
        }
        restoration = task
        defer { restoration = nil }
        try await task.value
    }
    private func remember(_ device: BluetoothDeviceRow?) async throws {
        try await restore()
        guard let store else { throw DocumentStorageError.invalidConfiguration }
        let saved = try await store.save(
            .init(id: device?.id, name: device?.name, automaticallyReconnect: device != nil && reconnectEnabled),
            expecting: revision)
        revision = saved.revision
        state.remembered = device
    }
    private func apply(_ value: NexArmBluetoothSnapshot) {
        switch value.power {
        case .poweredOn: state.availability = .available
        case .poweredOff: state.availability = .poweredOff
        case .unauthorized: state.availability = .denied
        case .unsupported: state.availability = .unsupported
        case .unknown, .resetting: state.availability = .unknown
        }
        state.scanning = false
        if discoveryVisible && (state.phase == .idle || state.phase == .failed) {
            state.scanning = value.scanning
            state.nearby = value.devices.compactMap {
                guard let name = NexArmBluetoothDevice.discoveryName(advertised: $0.name, cached: nil) else {
                    return nil
                }
                return .init(id: $0.id, name: name)
            }
        } else {
            state.nearby = []
        }
        if let selected = value.selected, state.selected?.id == selected.id {
            state.selected = .init(id: selected.id, name: selected.name)
        }
        if value.phase == .disconnected && controller != nil {
            recoverOnDisconnect = foreground && reconnectEnabled && !manualDisconnectPending && !forgetRequested
            controller = nil
            motion?.cancel()
            state.phase = .idle
            state.controlValidated = false
            state.error = value.failure ?? "机械臂连接已断开，请重新连接"
        }
        if value.phase == .disconnecting && controller != nil {
            recoverOnDisconnect = foreground && reconnectEnabled && !manualDisconnectPending && !forgetRequested
            controller = nil
            motion?.cancel()
            state.phase = .disconnecting
            state.error = value.failure
        }
        if value.phase == .disconnected && state.phase == .disconnecting && cleanup == nil && operation == nil {
            state.phase = .idle
        }
        if discoveryVisible && value.discoveryLimitReached { state.notice = "附近设备较多，请靠近机械臂后重新搜索" }
        if let failure = value.failure, operation == nil, cleanup == nil, state.selected != nil {
            state.error = failure
        }
        if value.phase == .disconnected, recoverOnDisconnect {
            recoverOnDisconnect = false
            recoveryAttempted = false
            state.error = nil
            state.notice = "正在恢复连接…"
            scheduleReconnect()
        }
    }
    public func openPage() {
        pageVisible = true
        if state.phase != .connected { scan() }
    }
    public func closePage() {
        pageVisible = false
        stopScan()
    }
    public func scan() {
        guard foreground, operation == nil, cleanup == nil, state.phase != .connected else { return }
        state.error = nil
        state.notice = nil
        scanWanted = true
        discoveryVisible = true
        applyDiscoveryIntent()
    }
    public func stopScan() {
        scanWanted = false
        applyDiscoveryIntent()
    }
    private func applyDiscoveryIntent() {
        guard discovery == nil else { return }
        discovery = Task {
            defer { discovery = nil }
            while true {
                let wanted = scanWanted && foreground
                do {
                    if wanted { try await link.scan() } else { await link.stopScan() }
                } catch {
                    state.error = Self.message(error)
                }
                if wanted == (scanWanted && foreground) { return }
            }
        }
    }
    public func connect(_ id: UUID) {
        recovery?.cancel()
        recoveryAttempted = true
        connect(id, automatically: false)
    }
    private func connect(_ id: UUID, automatically: Bool) {
        guard foreground, operation == nil, cleanup == nil, motion == nil, controller == nil else {
            state.error = Self.message(BluetoothWorkflowError.busy)
            return
        }
        guard
            let device = state.nearby.first(where: { $0.id == id })
                ?? (state.remembered?.id == id ? state.remembered : nil)
                ?? (state.selected?.id == id ? state.selected : nil)
        else {
            state.error = "设备已不在列表中，请重新搜索"
            return
        }
        stopScan()
        discoveryVisible = false
        generation = UUID()
        let token = generation
        if !automatically { reconnectEnabled = false }
        state.selected = device
        state.nearby = []
        state.scanning = false
        state.joints = []
        jogPlanner = nil
        armPlan = nil
        state.pose = []
        state.sampledAt = nil
        state.controlValidated = false
        state.phase = .connecting
        state.error = nil
        state.notice = nil
        state.motionStatus = nil
        operation = Task {
            defer { operation = nil }
            do {
                await discovery?.value
                try Task.checkCancellation()
                try await restore()
                if !automatically { reconnectEnabled = false }
                await quiesce()
                try Task.checkCancellation()
                try await link.connect(id)
                await link.clearDiscovery()
                try Task.checkCancellation()
                guard foreground, token == generation else { throw CancellationError() }
                try await verifyConnection(
                    device: device, candidate: NexArmController(link: link, compatibilityPolicy: .nexArmBLEProtocol),
                    token: token, indicate: !automatically)
            } catch {
                let failed = await link.status()
                if token == generation {
                    controller = nil
                    state.phase = .failed
                    state.controlValidated = false
                    state.error = failed.failure ?? Self.message(error)
                }
                await link.disconnect()
                if !automatically, reconnectEnabled, foreground, token == generation,
                    failed.phase != .connected
                {
                    recoveryAttempted = false
                    scheduleReconnect()
                }
            }
        }
    }
    private func verifyConnection(
        device: BluetoothDeviceRow, candidate: NexArmController, token: UUID, indicate: Bool = true
    ) async throws {
        state.phase = .verifying
        state.controlValidated = false
        state.error = nil
        state.notice = nil
        _ = try await candidate.verifyCompatibility()
        let preparedPlan = try await candidate.prepareArmControl()
        try Task.checkCancellation()
        guard foreground, token == generation else { throw CancellationError() }
        armPlan = preparedPlan
        reconnectEnabled = true
        try await remember(device)
        let ready = await link.status()
        try Task.checkCancellation()
        guard ready.phase == .connected, ready.selected?.id == device.id, token == generation, foreground else {
            throw NexArmError.disconnected
        }
        var indicationUnconfirmed = false
        if indicate {
            state.phase = .indicating
            state.executing = true
            state.motionStatus = "正在准备机械臂…"
            let indication = Task { try await candidate.indicateConnection() }
            motion = indication
            defer {
                motion = nil
                state.executing = false
            }
            do {
                try await withTaskCancellationHandler {
                    try await indication.value
                } onCancel: {
                    indication.cancel()
                }
            } catch {
                try Task.checkCancellation()
                guard token == generation, foreground else { throw CancellationError() }
                switch error as? NexArmError {
                case .uncertainMotion, .moving, .invalidMotion: break
                default: throw error
                }
                // A feedback gesture is not the Bluetooth handshake. Leave the connected
                // controller available for read-only recovery before the next explicit command.
                indicationUnconfirmed = true
                state.motionStatus = "连接提示动作未确认完成"
            }
            try Task.checkCancellation()
            let current = await link.status()
            guard foreground, token == generation, current.phase == .connected, current.selected?.id == device.id else {
                throw NexArmError.disconnected
            }
            if !indicationUnconfirmed { state.motionStatus = "连接提示已完成" }
        }
        armPlan = preparedPlan
        reconnectEnabled = true
        try await remember(device)
        try Task.checkCancellation()
        let finalState = await link.status()
        guard foreground, token == generation, finalState.phase == .connected, finalState.selected?.id == device.id
        else {
            throw NexArmError.disconnected
        }
        if !indicationUnconfirmed {
            let sample = try await candidate.readState()
            try Task.checkCancellation()
            guard foreground, token == generation else { throw CancellationError() }
            updateTelemetry(sample)
        }
        controller = candidate
        state.phase = .connected
        state.controlValidated = true
        state.error = nil
        state.nearby = []
        state.scanning = false
        state.notice = indicate ? "已连接，可以返回对话控制机械臂" : "已自动恢复连接，可以继续控制机械臂"
    }
    public func disconnect() { disconnect(preserveReconnect: false) }
    private func disconnect(preserveReconnect: Bool) {
        recovery?.cancel()
        stopMotorControl()
        resetRequested = false
        liveTask?.cancel()
        recoverOnDisconnect = false
        if !preserveReconnect {
            reconnectEnabled = false
            manualDisconnectPending = true
        }
        stopScan()
        discoveryVisible = false
        guard cleanup == nil else { return }
        generation = UUID()  // Immediately fence in-flight connection verification.
        controller = nil
        state.joints = []
        jogPlanner = nil
        armPlan = nil
        state.pose = []
        state.sampledAt = nil
        state.controlValidated = false
        operation?.cancel()
        motion?.cancel()
        let pending = operation
        let movement = motion
        state.phase = .disconnecting
        cleanup = Task {
            defer { cleanup = nil }
            if movement == nil { await link.disconnect() }
            await pending?.value
            await liveTask?.value
            if let movement {
                do { try await movement.value } catch {
                    if !(error is CancellationError) { state.error = Self.message(error) }
                }
            }
            await link.disconnect()
            await link.clearDiscovery()
            state.nearby = []
            state.scanning = false
            let closed = await link.status()
            state.phase = closed.phase == .disconnected ? .idle : .disconnecting
            if let failure = closed.failure { state.error = failure }
            state.controlValidated = false
            state.executing = false
            if manualDisconnectPending {
                reconnectEnabled = false
                if !forgetRequested {
                    do { try await remember(state.remembered) } catch { state.error = error.localizedDescription }
                }
                manualDisconnectPending = false
            }
            if forgetRequested {
                forgetRequested = false
                do {
                    try await link.forgetDevice()
                    try await remember(nil)
                    state.selected = nil
                    state.nearby = []
                    state.scanning = false
                    state.motionStatus = nil
                    state.error = nil
                    state.notice = nil
                    recoveryAttempted = true
                } catch { state.error = "移除设备记录失败：\(error.localizedDescription)" }
            }
        }
    }
    public func forget() {
        forgetRequested = true
        state.nearby = []
        state.error = nil
        state.motionStatus = nil
        state.notice = nil
        disconnect()
    }
    public func setForeground(_ active: Bool) {
        let changed = foreground != active
        foreground = active
        if !active {
            recoveryAttempted = false
            disconnect(preserveReconnect: true)
        } else if changed {
            scheduleReconnect()
        }
    }
    /// One attempt per foreground activation or established-link loss. No timer retries or gesture replay.
    private func scheduleReconnect() {
        guard foreground, !recoveryAttempted, recovery == nil else { return }
        recoveryAttempted = true
        recovery = Task {
            defer {
                recovery = nil
                if foreground && !recoveryAttempted { scheduleReconnect() }
            }
            do {
                try await restore()
                await cleanup?.value
                await operation?.value
                if let motion {
                    do { try await motion.value } catch {
                        // Join prior work without replaying it; its caller owns the failure.
                    }
                }
                try Task.checkCancellation()
                guard foreground, reconnectEnabled, controller == nil, let device = state.remembered else { return }
                await discovery?.value
                var snapshot = await link.status()
                if snapshot.power == .unknown || snapshot.power == .resetting {
                    try await link.scan()  // Initialize CoreBluetooth; foreground discovery only.
                    for _ in 0..<20 {
                        try Task.checkCancellation()
                        snapshot = await link.status()
                        if snapshot.power != .unknown && snapshot.power != .resetting { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    await link.stopScan()
                }
                try Task.checkCancellation()
                guard foreground, reconnectEnabled, cleanup == nil, operation == nil,
                    snapshot.power == .poweredOn, snapshot.phase == .disconnected
                else { return }
                connect(device.id, automatically: true)
                await operation?.value
            } catch {
                if !(error is CancellationError) { state.error = Self.message(error) }
            }
        }
    }
    public func waitUntilIdle() async {
        await discovery?.value
        await operation?.value
        await cleanup?.value
        await recovery?.value
        await liveTask?.value
    }
    public func openSystemSettings() {
        #if os(iOS)
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        #endif
    }
    private func updateTelemetry(_ sample: (joints: [Int], pose: [Int])) {
        state.joints = sample.joints
        if liveTask == nil { jogPlanner = try? NexArmJogPlanner(positions: sample.joints) }
        state.pose = sample.pose
        state.sampledAt = Date()
    }
    public func refreshDevice() async {
        guard foreground, state.controlReady, !state.executing, liveTask == nil, operation == nil,
            cleanup == nil, let controller
        else { return }
        let token = generation
        let revision = controlRevision
        state.refreshing = true
        let task = Task { @MainActor in
            defer { state.refreshing = false }
            do {
                let sample = try await controller.recoverState()
                try Task.checkCancellation()
                guard token == generation, revision == controlRevision, state.controlReady else { return }
                updateTelemetry(sample)
                state.error = nil
            } catch {
                if token == generation, revision == controlRevision { state.error = Self.message(error) }
            }
        }
        operation = task
        await task.value
        operation = nil
    }
    public func tryAction(_ action: BluetoothArmAction) {
        guard foreground, state.controlReady else {
            state.error = Self.message(BluetoothWorkflowError.disconnected)
            return
        }
        stopMotorControl()
        resetRequested = action == .reset
        state.resetting = resetRequested
        state.error = nil
        if action != .reset {
            let gesture: NexArmGesture
            switch action {
            case .shakeBase: gesture = .baseSway
            case .nod: gesture = .nod
            case .shakeHead: gesture = .shakeHead
            case .wave: gesture = .wave
            case .tiltLeft: gesture = .tiltLeft
            case .tiltRight: gesture = .tiltRight
            case .lookAround: gesture = .lookAround
            case .celebrate: gesture = .celebrate
            case .dance: gesture = .dance
            case .reset: return
            }
            do {
                guard let armPlan, let jogPlanner else { throw NexArmError.invalidMotion }
                testFrames = try armPlan.compile(gesture.settingsTestFrames(), from: jogPlanner.targets.map { Int($0) })
            } catch {
                state.error = Self.message(error)
                return
            }
            testDue = .now
            testLabel = action.title
            state.testing = true
            state.motionStatus = "正在发送\(testLabel)"
        }
        startLiveControl()
    }
    public func setMotorVelocity(id: Int, value: Double) {
        guard (1...6).contains(id), value.isFinite else { return }
        if value == 0 {
            motorInputs[id - 1] = 0
            return
        }
        guard foreground, state.controlReady else {
            state.error = Self.message(BluetoothWorkflowError.disconnected)
            return
        }
        cancelTestSequence()
        resetRequested = false
        state.resetting = false
        motorInputs[id - 1] = min(1, max(-1, value))
        startLiveControl()
    }
    private func cancelTestSequence() {
        if state.testing { state.motionStatus = "测试指令已中断" }
        testID = UUID()
        testFrames = []
        state.testing = false
    }
    public func stopMotorControl() {
        motorInputs = Array(repeating: 0, count: 6)
        cancelTestSequence()
    }
    private func startLiveControl() {
        guard liveTask == nil, let controller else { return }
        controlRevision = UUID()
        let revision = controlRevision
        let connectedGeneration = generation
        motion?.cancel()
        state.error = nil
        state.jogging = true
        liveTask = Task {
            var session: UUID?
            var failed = false
            var nextMotorIndex = 0
            do {
                let token = try await link.beginLiveControl()
                session = token
                if jogPlanner == nil {
                    jogPlanner = try NexArmJogPlanner(positions: await controller.cachedJoints)
                }
                var stalledSince: ContinuousClock.Instant?
                var admittedTestID = testID
                var lastTick = ContinuousClock.now.advanced(by: .milliseconds(-30))
                while true {
                    let tickStart = ContinuousClock.now
                    let duration = tickStart - lastTick
                    let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                    lastTick = tickStart
                    if admittedTestID != testID {
                        admittedTestID = testID
                        stalledSince = nil
                    }
                    try Task.checkCancellation()
                    guard foreground, generation == connectedGeneration, state.controlReady else {
                        throw CancellationError()
                    }
                    if resetRequested {
                        guard let armPlan, let planner = jogPlanner else { throw NexArmError.invalidMotion }
                        let packet = try armPlan.home(from: planner.targets.map { Int($0) }).packet
                        let submittedID = testID
                        if try await link.sendLive(packet, session: token) {
                            guard submittedID == testID else { continue }
                            resetRequested = false
                            state.resetting = false
                            jogPlanner = try NexArmJogPlanner(
                                positions: NexArmArmPlan.applying(packet, to: planner.targets.map { Int($0) }))
                            state.motionStatus = "已发送重置指令"
                            stalledSince = nil
                        } else {
                            stalledSince = stalledSince ?? .now
                        }
                    } else if let frame = testFrames.first {
                        if tickStart >= testDue {
                            let submittedID = testID
                            if try await link.sendLive(frame.packet, session: token) {
                                if submittedID == testID {
                                    guard let planner = jogPlanner else { throw NexArmError.invalidMotion }
                                    jogPlanner = try NexArmJogPlanner(
                                        positions: NexArmArmPlan.applying(
                                            frame.packet, to: planner.targets.map { Int($0) }))
                                    testFrames.removeFirst()
                                    testDue = .now.advanced(by: .milliseconds(frame.milliseconds))
                                    if testFrames.isEmpty {
                                        state.testing = false
                                        state.motionStatus = "已发送\(testLabel)全部指令"

                                    }
                                }
                                stalledSince = nil
                            } else {
                                stalledSince = stalledSince ?? .now
                            }
                        }
                    } else {
                        let startIndex = nextMotorIndex
                        for offset in 0..<6 {
                            let index = (startIndex + offset) % 6
                            try Task.checkCancellation()
                            if resetRequested || !testFrames.isEmpty { break }
                            if abs(motorInputs[index]) <= 0.04 {
                                jogPlanner?.stop(id: index + 1)
                                continue
                            }
                            guard
                                let proposed = try jogPlanner?.proposal(
                                    id: index + 1,
                                    deflection: motorInputs[index], elapsed: elapsed)
                            else { continue }
                            guard let packet = proposed.packet else {
                                jogPlanner?.accept(proposed)
                                continue
                            }
                            if try await link.sendLive(packet, session: token) {
                                jogPlanner?.accept(proposed)
                                nextMotorIndex = (index + 1) % 6
                                if state.motionStatus != "手动控制中" { state.motionStatus = "手动控制中" }
                                stalledSince = nil
                            } else {
                                stalledSince = stalledSince ?? .now
                                nextMotorIndex = index
                                break
                            }
                        }
                    }
                    for index in 0..<6 where abs(motorInputs[index]) <= 0.04 {
                        jogPlanner?.stop(id: index + 1)
                    }
                    if let stalledSince, ContinuousClock.now - stalledSince > .seconds(2) { throw NexArmError.timeout }
                    if !resetRequested && testFrames.isEmpty && motorInputs.allSatisfy({ abs($0) <= 0.04 })
                        && motion == nil
                    {
                        break
                    }
                    try await Task.sleep(until: tickStart.advanced(by: .milliseconds(30)), clock: .continuous)
                }
            } catch {
                failed = true
                if !(error is CancellationError), generation == connectedGeneration {
                    state.error = Self.message(error)
                }
            }
            if let session { await link.endLiveControl(session) }
            let restart =
                !failed && foreground && generation == connectedGeneration && state.controlReady
                && (resetRequested || !testFrames.isEmpty || motorInputs.contains { abs($0) > 0.04 })
            if controlRevision == revision {
                if failed {
                    motorInputs = Array(repeating: 0, count: 6)
                    resetRequested = false
                    cancelTestSequence()
                }
                state.resetting = resetRequested
                state.jogging = false
                if state.motionStatus == "手动控制中" { state.motionStatus = "手动控制已结束" }
            }
            liveTask = nil
            if restart { startLiveControl() }
        }
    }
    /// Conversation/channel admission retains completion-based execution.
    public func shakeBase(cycles: Int) async throws {
        guard (1...3).contains(cycles) else { throw NexArmError.invalidMotion }
        try await runMotion(label: "左右晃动 \(cycles) 次") { try await $0.performGesture(.baseSway, repetitions: cycles) }
    }
    public func performGesture(_ gesture: NexArmGesture, repetitions: Int) async throws {
        try await runMotion(label: gesture.displayName) {
            try await $0.performGesture(gesture, repetitions: repetitions)
        }
    }
    private func runMotion(
        label: String, returnsHome: Bool = true, perform: @escaping @Sendable (NexArmController) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard foreground else { throw BluetoothWorkflowError.background }
        guard operation == nil, cleanup == nil, motion == nil, liveTask == nil else {
            throw BluetoothWorkflowError.busy
        }
        guard state.phase == .connected, let controller else { throw BluetoothWorkflowError.disconnected }
        guard state.controlReady else { throw BluetoothWorkflowError.controlNotReady }
        let token = UUID()
        let connectedGeneration = generation
        let revision = controlRevision
        motionID = token
        state.executing = true
        state.error = nil
        state.motionStatus = "正在\(label)…"
        var failureDetail: NexArmMotionFailure?
        let task = Task {
            do {
                try Task.checkCancellation()
                try await perform(controller)
            } catch {
                failureDetail = await controller.motionFailure
                throw error
            }
        }
        motion = task
        defer {
            motion = nil
            motionID = nil
            state.executing = false
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { @MainActor [weak self] in
                    if self?.motionID == token { self?.motion?.cancel() }
                }
            }
            try Task.checkCancellation()
            guard connectedGeneration == generation, revision == controlRevision else { throw CancellationError() }
            let sample = await controller.latestState
            try Task.checkCancellation()
            guard connectedGeneration == generation, revision == controlRevision else { throw CancellationError() }
            updateTelemetry(sample)
            state.motionStatus = "已完成\(label)" + (returnsHome ? "并回位" : "")
        } catch {
            guard controlRevision == revision else { throw CancellationError() }
            state.motionStatus = error is CancellationError ? "动作已取消，未继续后续步骤" : "动作未完成"
            state.error = Self.message(error)
            if error as? NexArmError == .uncertainMotion {
                // Completion uncertainty is not a disconnected transport. Keep the owner so
                // refresh/the next explicit request can revalidate stationary feedback.
                state.motionStatus = "动作未确认完成"
                switch failureDetail {
                case .sending: state.error = "动作指令未能发送，可直接再试其他动作或重置"
                case .pose: state.error = "机械臂尚未到达动作姿态，可直接再试其他动作或重置"
                case .feedbackTimeout: state.error = "动作反馈超时，结果未知，可重新发起动作或重置"
                case .completionTimeout: state.error = "动作未在期限内到位，可重新发起动作或重置"
                case .feedback: state.error = "暂未读到机械臂位置，可直接再试其他动作或重置"
                case .target(let joints):
                    state.error =
                        joints.isEmpty
                        ? "机械臂尚未稳定，可直接再试其他动作或重置"
                        : "舵机 \(joints.map(String.init).joined(separator: "、")) 尚未到达动作位置，可直接再试其他动作或重置"
                case nil: break
                }
            }
            if error as? NexArmError == .invalidMotion { throw BluetoothWorkflowError.posture }
            if error as? NexArmError == .uncertainMotion {
                if failureDetail == .feedbackTimeout { throw BluetoothWorkflowError.feedbackTimeout }
                if failureDetail == .completionTimeout { throw BluetoothWorkflowError.completionTimeout }
                throw BluetoothWorkflowError.unverified
            }
            throw error
        }
    }
    private static func message(_ error: any Error) -> String {
        if let error = error as? BluetoothWorkflowError { return error.localizedDescription }
        if error is CancellationError { return "操作已取消" }
        switch error as? NexArmError {
        case .firmwareUnavailable: return "设备验证未完成，请重新连接"
        case .unsupportedFirmware: return "当前固件尚未验证，暂不能控制这台机械臂"
        case .moving: return "机械臂尚未静止，请稍后重试"
        case .invalidMotion: return BluetoothWorkflowError.posture.localizedDescription
        case .uncertainMotion: return BluetoothWorkflowError.unverified.localizedDescription
        case .busy: return BluetoothWorkflowError.busy.localizedDescription
        case .disconnected: return BluetoothWorkflowError.disconnected.localizedDescription
        case .timeout: return "设备响应超时，请检查距离、供电及 Wonderbot 是否已断开"
        default: break
        }
        switch error as? NexArmBluetoothError {
        case .unavailable: return "蓝牙不可用，请检查系统蓝牙和应用权限"
        case .unknownDevice: return "未找到设备，请重新搜索"
        case .incompatibleService: return "设备的蓝牙服务不兼容，无法连接"
        default: return "连接失败：\(error.localizedDescription)"
        }
    }
}
