import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import PlatformKit
import Storage
import StorageDevices
import UI

#if os(iOS)
    import UIKit
#endif

/// Execution provenance belongs to App; never supplied to the Bluetooth SDK.
public struct NexArmControlOrigin: Sendable, Equatable {
    public let source: String
    public let sessionID: String
    public let inputID: String
    public let callID: String
    public init(source: String, sessionID: String, inputID: String, callID: String) {
        self.source = String(source.prefix(64))
        self.sessionID = sessionID
        self.inputID = inputID
        self.callID = callID
    }
}
public struct NexArmControlFailure: Sendable {
    public let workerID: String
    public let origin: NexArmControlOrigin?
    public let code: String
    public let message: String
    public var report: ActionReport? = nil
}

@MainActor
public final class BluetoothWorkflow: BluetoothControlling {
    public private(set) var lastManualFailure: NexArmControlFailure?
    public var manualOrigin: NexArmControlOrigin?
    public var manualFailureReporter: (@Sendable (NexArmControlFailure) async -> Void)?
    private func reportManualFailure(
        _ error: any Error, workerID: String, origin: NexArmControlOrigin?,
        reporter: (@Sendable (NexArmControlFailure) async -> Void)?
    ) async {
        let report = (error as? any ActionReportProviding)?.actionReport ?? ActionReport.empty.recordingFailure(error)
        let failure = NexArmControlFailure(
            workerID: workerID, origin: origin, code: ActionReport.code(for: error).rawValue,
            message: Self.message(error), report: report)
        lastManualFailure = failure
        if let reporter { await reporter(failure) }
    }
    public let state: BluetoothSettingsState
    private let link: any NexArmBluetoothLink
    private let makeDeviceRepository: @Sendable () throws -> any DeviceRepository
    private var records: (any DeviceRepository)?
    private var controller: NexArmActionController?
    private var operation: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var motion: Task<Void, any Error>?
    private var liveTask: Task<Void, Never>?
    private var motorInputs = Array(repeating: 0.0, count: 6)
    private var jogPlanner: NexArmJogPlanner?
    private struct AimGoal: Equatable, Sendable {
        var base: Int
        var lift: Int
        var elbow: Int
        var pitch: Int
    }
    private var aimGoal: AimGoal?
    private var forearmLeveler = NexArmForearmLeveler()
    private var followingAim = false
    private var controlRevision = UUID().uuidString
    private var manualRevision = UUID().uuidString
    private var pendingArmAction: BluetoothArmAction?
    private var settingsWorker: Task<Void, Never>?
    private var settingsPlayback: Task<Void, any Error>?
    public var withMotorResources:
        (@Sendable (Set<Int>, @escaping @Sendable () async throws -> Void) async throws -> Void)?
    /// Composition binds the current Photographer's monotonic pose freshness, independently of the radio.
    public var trackingInputAvailable: @Sendable () async -> Bool = { true }
    public var trackingAvailable: Bool {
        foreground && suspension == nil && state.controlReady && settingsWorker == nil && pendingArmAction == nil
            && !state.jogging
            && motion == nil && operation == nil && cleanup == nil
    }
    private var motionID: String?
    private var generation = UUID().uuidString
    private var foreground = true
    private var observing = false
    private var pageVisible = false
    private var scanWanted = false
    private var discoveryVisible = false
    private var discovery: Task<Void, Never>?
    private var forgetRequested = false
    private var reconnectEnabled = false
    private var manualDisconnectPending = false
    private var recovery: Task<Void, Never>?
    private var suspension: Task<Void, Never>?
    private var recoveryID = UUID().uuidString
    private var recoveryPending = false
    private var recoveryNeedsUser = false
    private var recoveryAttempts = 0
    private var recoveryStarted: ContinuousClock.Instant?
    private var recoveryCause = BluetoothRecoveryCause.resume
    private var connectionError: (any Error)?
    private var latestLinkSnapshot = NexArmBluetoothSnapshot() {
        didSet {
            state.transportIssue = BluetoothPresentation.currentIssue(latestLinkSnapshot)
            switch latestLinkSnapshot.power {
            case .poweredOn: state.availability = .available
            case .poweredOff: state.availability = .poweredOff
            case .unauthorized: state.availability = .denied
            case .unsupported: state.availability = .unsupported
            case .unknown, .resetting: state.availability = .unknown
            }
        }
    }

    public init(
        state: BluetoothSettingsState, link: any NexArmBluetoothLink,
        makeDeviceRepository: @escaping @Sendable () throws -> any DeviceRepository
    ) {
        self.state = state
        self.link = link
        self.makeDeviceRepository = makeDeviceRepository
    }
    public func run() async {
        guard !observing else { return }
        observing = true
        defer { observing = false }
        do { try await restore() } catch { state.error = "设备记录读取失败：\(error.localizedDescription)" }
        scheduleReconnect()
        for await value in link.updates {
            if Task.isCancelled { break }
            await apply(value)
        }
        disconnect(preserveReconnect: true)
        await waitUntilIdle()
    }
    private func restore() async throws {
        if records != nil { return }
        let records = try makeDeviceRepository()
        if let record = try await records.selectedDevice() {
            state.remembered = .init(id: record.id, name: record.name)
            reconnectEnabled = record.reconnect
        }
        self.records = records
    }
    private func remember(_ device: BluetoothDeviceRow?) async throws {
        try await restore()
        guard let records else { throw RecordStorageError.missingRecord }
        try await records.selectDevice(device?.id, reconnect: device != nil && reconnectEnabled)
        state.remembered = device
    }
    private func apply(_ value: NexArmBluetoothSnapshot) async {
        let mappingGeneration = generation
        if value.revision != 0, value.revision <= latestLinkSnapshot.revision { return }
        let previousPower = latestLinkSnapshot.power
        let feedbackChanged =
            value.feedbackPacket != latestLinkSnapshot.feedbackPacket
            || value.feedbackReceivedAt != latestLinkSnapshot.feedbackReceivedAt
        latestLinkSnapshot = value
        if feedbackChanged, let packet = value.feedbackPacket, let controller {
            let token = generation
            Task { @MainActor in
                do {
                    let sample = try await controller.receivePassiveFeedback(packet)
                    guard token == generation else { return }
                    updateTelemetry(sample, receivedAt: value.feedbackReceivedAt)
                } catch {
                    guard token == generation else { return }
                    // Native packet faults are diagnosed by the SDK; conversion failure is not a link fault.
                    return
                }
            }
        }
        state.scanning = false
        do {
            if discoveryVisible && (state.phase == .idle || state.phase == .failed) {
                state.scanning = value.scanning
                var nearby: [BluetoothDeviceRow] = []
                for device in value.devices.sorted(by: BluetoothPresentation.discoveryOrder) {
                    guard let name = BluetoothPresentation.deviceName(device.name) else { continue }
                    let id = try await makeDeviceRepository().device(nativeID: device.id, name: name)
                    nearby.append(.init(id: id, name: name))
                }
                guard mappingGeneration == generation, latestLinkSnapshot.revision == value.revision else { return }
                state.nearby = nearby
            } else {
                state.nearby = []
            }
            if let selected = value.selected {
                let id = try await makeDeviceRepository().device(nativeID: selected.id, name: selected.name)
                guard mappingGeneration == generation, latestLinkSnapshot.revision == value.revision else { return }
                if state.selected?.id == id {
                    state.selected = .init(
                        id: id, name: BluetoothPresentation.deviceName(selected.name) ?? "未命名设备")
                }
            }
        } catch {
            guard mappingGeneration == generation else { return }
            state.error = error.localizedDescription
            state.nearby = []
        }
        if discoveryVisible && value.discoveryLimitReached { state.notice = "附近设备较多，请靠近机械臂后重新搜索" }
        if controller != nil, operation == nil, cleanup == nil {
            if value.phase == .disconnecting || value.phase == .disconnected || value.queriesQuarantined {
                requestRecovery(cause(for: value), snapshot: value)
            }
        }
        if value.power != .poweredOn, previousPower == .poweredOn, reconnectEnabled,
            recovery == nil, cleanup == nil
        {
            requestRecovery(.power, snapshot: value)
        }
        if value.power == .poweredOn, previousPower != .poweredOn, recoveryPending,
            foreground, reconnectEnabled, recovery == nil, cleanup == nil
        {
            requestRecovery(recoveryCause, snapshot: value)
        }
    }
    /// Mirror native admission before a callable endpoint reports acceptance; UI protocol methods remain unchanged.
    public func validateControlAdmission(_ request: DeviceControlRequest) throws {
        switch request.operation {
        case .scan:
            guard foreground else { throw NexArmExecutionError.background }
            guard !state.recoveryStage.busy, operation == nil, cleanup == nil, state.phase != .connected else {
                throw NexArmExecutionError.busy
            }
        case .connect, .reconnect:
            guard foreground else { throw NexArmExecutionError.background }
            guard recovery == nil, cleanup == nil, operation == nil, controller == nil else {
                throw NexArmExecutionError.busy
            }
            guard let id = request.id, BusinessRecordID(rawValue: id)?.kind == .device,
                state.nearby.contains(where: { $0.id == id }) || state.remembered?.id == id || state.selected?.id == id
            else { throw DeviceControlError.unavailable }
        case .preset:
            guard foreground else { throw NexArmExecutionError.background }
            guard suspension == nil, state.canControl else { throw NexArmExecutionError.controlNotReady }
        case .motorVelocity:
            if request.value != 0 {
                guard foreground else { throw NexArmExecutionError.background }
                guard suspension == nil, state.canControl else { throw NexArmExecutionError.controlNotReady }
            }
        default: break
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
        guard foreground, !state.recoveryStage.busy, operation == nil, cleanup == nil, state.phase != .connected else {
            return
        }
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
    public func connect(_ id: String) {
        guard recovery == nil, cleanup == nil else {
            state.error = "正在恢复连接，请等待完成或先断开"
            return
        }
        resetRecoveryBudget()
        recoveryCause = .manual
        state.recoveryStage = .idle
        connect(id, automatically: false)
    }
    private func connect(_ id: String, automatically: Bool) {
        guard foreground, operation == nil, cleanup == nil, controller == nil else {
            state.error = "连接操作正在进行，请等待结束"
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
        generation = UUID().uuidString
        let token = generation
        connectionError = nil
        if !automatically { reconnectEnabled = false }
        state.selected = device
        state.nearby = []
        state.scanning = false
        state.joints = []
        jogPlanner = nil
        state.pose = []
        state.sampledAt = nil
        state.phase = .connecting
        state.error = nil
        state.notice = nil
        operation = Task {
            defer { operation = nil }
            do {
                await discovery?.value
                try Task.checkCancellation()
                try await restore()
                if !automatically { reconnectEnabled = false }
                try Task.checkCancellation()
                let nativeID = try await makeDeviceRepository().nativeDevice(id)
                try await link.connect(nativeID)
                await link.clearDiscovery()
                try Task.checkCancellation()
                guard foreground, token == generation else { throw CancellationError() }
                latestLinkSnapshot = await link.status()
                guard foreground, token == generation else { throw CancellationError() }
                let candidate = NexArmActionController(link: link, compatibilityPolicy: .passiveBLE)
                controller = candidate
                reconnectEnabled = true
                try await remember(device)
                try Task.checkCancellation()
                guard foreground, token == generation else { throw CancellationError() }
                state.phase = .connected
                state.notice = "已连接，正在监听机械臂反馈"
                resetRecoveryBudget()
            } catch {
                guard token == generation else { return }
                let failed = await link.status()
                guard token == generation else { return }
                connectionError = error
                latestLinkSnapshot = failed
                state.error = failed.failure.map(BluetoothPresentation.failure) ?? state.error ?? Self.message(error)
                state.phase = failed.phase == .connected ? .connected : .failed
                if !automatically, !(error is CancellationError) {
                    // Explicit device selection authorizes bounded recovery; no motion is replayed.
                    reconnectEnabled = true
                    requestRecovery(
                        cause(for: failed, fallback: .transport), snapshot: failed,
                        retry: BluetoothRecoveryPolicy.canRetry(error, snapshot: failed))
                }
            }
        }
    }

    public func disconnect() { disconnect(preserveReconnect: false) }
    private func disconnect(preserveReconnect: Bool, cancelRecovery: Bool = true) {
        if cancelRecovery {
            recoveryID = UUID().uuidString
            recovery?.cancel()
            recovery = nil
            recoveryPending = preserveReconnect && reconnectEnabled
            if preserveReconnect && recoveryNeedsUser {
                state.recoveryStage = .failed
            } else {
                state.recoveryStage = preserveReconnect && !foreground ? .suspended : .idle
            }
        }
        stopMotorControl()
        pendingArmAction = nil
        settingsWorker?.cancel()
        liveTask?.cancel()
        controlRevision = UUID().uuidString
        if !preserveReconnect {
            recoveryPending = false
            reconnectEnabled = false
            manualDisconnectPending = true
        }
        stopScan()
        discoveryVisible = false
        guard cleanup == nil else { return }
        generation = UUID().uuidString  // Immediately fence in-flight connection setup.
        controller = nil
        state.joints = []
        jogPlanner = nil
        state.pose = []
        state.sampledAt = nil
        operation?.cancel()
        // Closing the native session fails its in-flight Action naturally; recovery does not cancel it.
        let pending = operation
        let streaming = liveTask
        let settings = settingsWorker
        state.phase = .disconnecting
        cleanup = Task {
            defer { cleanup = nil }
            await link.disconnect()
            await pending?.value
            await streaming?.value
            // A fenced aim owner intentionally avoids publishing state; release its completed task here.
            liveTask = nil
            await settings?.value
            await link.disconnect()
            await link.clearDiscovery()
            state.nearby = []
            state.scanning = false
            let closed = await link.status()
            latestLinkSnapshot = closed
            state.phase =
                state.recoveryStage == .failed ? .failed : (closed.phase == .disconnected ? .idle : .disconnecting)
            if let failure = closed.failure { state.error = BluetoothPresentation.failure(failure) }
            state.jogging = false
            followingAim = false
            forearmLeveler = NexArmForearmLeveler()
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
                    state.error = nil
                    state.notice = nil
                    recoveryPending = false
                } catch { state.error = "移除设备记录失败：\(error.localizedDescription)" }
            }
        }
    }
    public func forget() {
        forgetRequested = true
        state.nearby = []
        state.error = nil
        state.notice = nil
        disconnect()
    }
    public func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if !active {
            // Stop software effects independently of healthy native connection ownership.
            motion?.cancel()
            if controller != nil, state.phase == .connected, operation == nil, cleanup == nil {
                suspendControl()
            } else {
                disconnect(preserveReconnect: true)
            }
        } else {
            resetRecoveryBudget()
            scheduleReconnect()
        }
    }
    private func suspendControl() {
        // A foreground verification waiter is not a failed native connection. Cancel it
        // without tearing down the healthy link when another background event arrives.
        recoveryID = UUID().uuidString
        recovery?.cancel()
        recovery = nil
        recoveryPending = false
        state.recoveryStage = .idle
        stopScan()
        discoveryVisible = false
        stopMotorControl()
        settingsWorker?.cancel()
        liveTask?.cancel()
        controlRevision = UUID().uuidString
        guard suspension == nil else { return }
        let token = generation
        let movement = motion
        let streaming = liveTask
        let settings = settingsWorker
        suspension = Task {
            defer { suspension = nil }
            if let movement { _ = await movement.result }
            await streaming?.value
            await settings?.value
            // The invocation owning motion must also retire its result/report scope.
            while motion != nil { await Task.yield() }
            guard token == generation else { return }
            liveTask = nil
            state.jogging = false
            followingAim = false
            jogPlanner = nil
            forearmLeveler = NexArmForearmLeveler()
        }
    }
    private func scheduleReconnect() {
        guard foreground, !recoveryNeedsUser, recovery == nil else { return }
        let identity = recoveryID
        recovery = Task { [self] in
            do { try await restore() } catch {
                state.error = "设备记录读取失败：\(Self.message(error))"
            }
            await suspension?.value
            await cleanup?.value
            guard identity == recoveryID, !Task.isCancelled else { return }
            let native = await link.status()
            guard identity == recoveryID, !Task.isCancelled else { return }
            latestLinkSnapshot = native
            recovery = nil
            guard foreground, reconnectEnabled else { return }
            if controller != nil, state.phase == .connected, native.phase == .connected,
                native.power == .poweredOn, !native.queriesQuarantined
            {
                state.recoveryStage = .idle
                return
            }
            requestRecovery(.resume, snapshot: native)
        }
    }

    private func cause(
        for snapshot: NexArmBluetoothSnapshot, fallback: BluetoothRecoveryCause = .disconnected
    ) -> BluetoothRecoveryCause {
        if snapshot.failure == .sendBlocked { return .congestion }
        if case .requestInterrupted = snapshot.failure { return .interrupted }
        if case .protocolViolation = snapshot.failure { return .protocolFailure }
        if snapshot.queriesQuarantined { return .query }
        if case .responseTimeout = snapshot.failure { return .query }
        if snapshot.power != .poweredOn { return .power }
        return snapshot.failure == nil ? fallback : .transport
    }
    private func resetRecoveryBudget() {
        recoveryAttempts = 0
        recoveryNeedsUser = false
        recoveryPending = false
        recoveryStarted = nil
        state.recoveryAttempt = 0
    }
    public func reconnect(_ id: String) {
        guard foreground, recovery == nil else { return }
        guard
            let device = state.selected.flatMap({ $0.id == id ? $0 : nil })
                ?? state.remembered.flatMap({ $0.id == id ? $0 : nil })
                ?? state.nearby.first(where: { $0.id == id })
        else { return }
        state.selected = device
        reconnectEnabled = true
        resetRecoveryBudget()
        requestRecovery(.manual, snapshot: latestLinkSnapshot)
    }
    private func requestRecovery(
        _ cause: BluetoothRecoveryCause, snapshot: NexArmBluetoothSnapshot, retry: Bool = true
    ) {
        guard !manualDisconnectPending, !forgetRequested, !recoveryNeedsUser, reconnectEnabled,
            let device = state.selected ?? state.remembered
        else { return }
        latestLinkSnapshot = snapshot
        guard foreground else {
            recoveryPending = true
            return
        }
        if recovery != nil { return }
        recoveryStarted = recoveryStarted ?? .now
        recoveryCause = cause
        recoveryPending = false
        recoveryID = UUID().uuidString
        let identity = recoveryID
        state.recoveryDeviceID = device.id
        state.recoveryStage = .cleaning
        state.notice = cause.rawValue
        // Immediate fencing occurs before yielding to the cleanup task.
        disconnect(preserveReconnect: true, cancelRecovery: false)
        recovery = Task { [self] in
            let deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: BluetoothRecoveryPolicy.episodeTimeout) } catch { return }
                guard let self, identity == self.recoveryID else { return }
                self.disconnect(preserveReconnect: true, cancelRecovery: false)
                self.recovery?.cancel()
                self.finishRecoveryFailure(BluetoothRecoveryError.episodeTimeout)
            }
            defer {
                deadline.cancel()
                if identity == recoveryID { recovery = nil }
            }
            await cleanup?.value
            guard identity == recoveryID, !Task.isCancelled else { return }
            let closed = await link.status()
            latestLinkSnapshot = closed
            guard closed.phase == .disconnected else {
                finishRecoveryFailure(BluetoothRecoveryError.disconnectUnconfirmed)
                return
            }
            guard retry else {
                finishRecoveryFailure(connectionError ?? BluetoothRecoveryError.notRetryable)
                return
            }
            while recoveryAttempts < BluetoothRecoveryPolicy.maximumAttempts {
                guard identity == recoveryID, !Task.isCancelled, foreground, reconnectEnabled else { return }
                var native = await link.status()
                if native.power == .unknown || native.power == .resetting {
                    do { try await link.scan() } catch {
                        state.error = Self.message(error)
                    }
                    for _ in 0..<20 {
                        if Task.isCancelled { return }
                        native = await link.status()
                        if native.power != .unknown && native.power != .resetting { break }
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                    await link.stopScan()
                }
                guard identity == recoveryID, !Task.isCancelled else { return }
                if native.power == .unauthorized || native.power == .unsupported {
                    finishRecoveryFailure(NexArmBluetoothError.unavailable)
                    return
                }
                guard native.power == .poweredOn else {
                    recoveryPending = true
                    recoveryStarted = nil
                    state.recoveryStage = .waitingForBluetooth
                    state.notice = "等待蓝牙恢复后继续连接"
                    return
                }
                if let started = recoveryStarted,
                    ContinuousClock.now - started >= BluetoothRecoveryPolicy.episodeTimeout
                {
                    finishRecoveryFailure(BluetoothRecoveryError.episodeTimeout)
                    return
                }
                let attempt = recoveryAttempts + 1
                state.recoveryStage = .waiting
                state.notice = "等待重新连接，第 \(attempt)/3 次"
                do { try await Task.sleep(for: BluetoothRecoveryPolicy.delay(attempt: attempt)) } catch {
                    return
                }
                guard identity == recoveryID, !Task.isCancelled, foreground, reconnectEnabled else { return }
                recoveryAttempts = attempt
                state.recoveryAttempt = attempt
                state.recoveryStage = .connecting
                connect(device.id, automatically: true)
                await operation?.value
                guard identity == recoveryID, !Task.isCancelled else { return }
                native = await link.status()
                latestLinkSnapshot = native
                if controller != nil, state.phase == .connected, native.phase == .connected {
                    resetRecoveryBudget()
                    state.recoveryStage = .idle
                    state.error = nil
                    state.notice = "蓝牙连接已恢复；动作发送与执行尚未验证，中断动作未重放"
                    return
                }
                let failure = connectionError ?? NexArmError.disconnected
                let retry = BluetoothRecoveryPolicy.canRetry(failure, snapshot: native)
                state.recoveryStage = .cleaning
                state.notice = cause.rawValue
                disconnect(preserveReconnect: true, cancelRecovery: false)
                await cleanup?.value
                guard identity == recoveryID, !Task.isCancelled else { return }
                native = await link.status()
                latestLinkSnapshot = native
                guard native.phase == .disconnected else {
                    finishRecoveryFailure(BluetoothRecoveryError.disconnectUnconfirmed)
                    return
                }
                guard retry else {
                    finishRecoveryFailure(failure)
                    return
                }
            }
            finishRecoveryFailure(connectionError ?? NexArmError.disconnected)
        }
    }
    private func finishRecoveryFailure(_ error: any Error) {
        recoveryPending = false
        recoveryNeedsUser = true
        state.recoveryStage = .failed
        state.phase = .failed
        let description = error is BluetoothRecoveryError ? Self.message(error) : (state.error ?? Self.message(error))
        state.error = "恢复未完成：\(description)"
        state.notice = "请检查设备后手动重新连接"
    }
    public func waitUntilIdle() async {
        repeat {
            await discovery?.value
            await operation?.value
            await cleanup?.value
            await recovery?.value
            await suspension?.value
            await liveTask?.value
            await settingsWorker?.value
            await Task.yield()
        } while discovery != nil || operation != nil || cleanup != nil || recovery != nil
            || suspension != nil || liveTask != nil || settingsWorker != nil
    }
    public func openSystemSettings() {
        #if os(iOS)
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        #endif
    }
    private func updateTelemetry(_ sample: (joints: [Int], pose: [Int]), receivedAt: ContinuousClock.Instant? = nil) {
        state.joints = sample.joints
        if liveTask == nil { jogPlanner = try? NexArmJogPlanner(positions: sample.joints) }
        state.pose = sample.pose
        let age = receivedAt.map { ContinuousClock.now - $0 } ?? .zero
        let seconds = Double(age.components.seconds) + Double(age.components.attoseconds) / 1e18
        state.sampledAt = Date(timeIntervalSinceNow: -seconds)
    }
    public func refreshDevice() async {
        guard foreground, state.phase == .connected, let controller else { return }
        let token = generation
        let snapshot = await link.status()
        guard token == generation else { return }
        guard let packet = snapshot.feedbackPacket else {
            state.notice = "等待机械臂位置回包，可以继续手动控制"
            return
        }
        do {
            let sample = try await controller.receivePassiveFeedback(packet)
            guard token == generation else { return }
            updateTelemetry(sample, receivedAt: snapshot.feedbackReceivedAt)
        } catch {
            guard token == generation else { return }
            // Read-only presentation refresh cannot initiate recovery or execution diagnostics.
            return
        }
    }
    public func tryAction(_ action: BluetoothArmAction) {
        guard foreground, suspension == nil, state.canControl else {
            return
        }
        manualRevision = UUID().uuidString
        motorInputs = Array(repeating: 0, count: 6)
        aimGoal = nil
        liveTask?.cancel()
        motion?.cancel()
        settingsPlayback?.cancel()
        pendingArmAction = action  // Capacity one; Settings explicitly replaces its previous request.
        guard settingsWorker == nil else { return }
        settingsWorker = Task {
            defer {
                settingsWorker = nil
            }
            while let action = pendingArmAction {
                let intent = manualRevision
                pendingArmAction = nil
                await liveTask?.value
                await joinCancelledControl()
                if intent != manualRevision { continue }
                guard !Task.isCancelled, foreground, state.canControl, let controller else { return }
                let connectedGeneration = generation
                let origin = manualOrigin
                let reporter = manualFailureReporter
                let playback = Task {
                    let gesture: NexArmGesture?
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
                    case .reset: gesture = nil
                    }
                    let plan = try await controller.manualPlan(gesture: gesture)
                    try Task.checkCancellation()
                    jogPlanner = nil  // Jog takeover must seed from the executor's latest measured feedback.
                    try await controller.performPlan(plan, completion: NexArmMotorCompletion())
                    let sample = await controller.latestState
                    try Task.checkCancellation()
                    guard foreground, generation == connectedGeneration, manualRevision == intent else {
                        throw CancellationError()
                    }
                    updateTelemetry(sample)
                    jogPlanner = try NexArmJogPlanner(positions: sample.joints)
                }
                settingsPlayback = playback
                let result = await playback.result
                settingsPlayback = nil
                guard generation == connectedGeneration else { return }
                switch result {
                case .success: break
                case .failure(let error):
                    if pendingArmAction == nil, !Task.isCancelled, !(error is CancellationError) {
                        // Record this worker failure independently, then admit the next intent.
                        await reportManualFailure(error, workerID: intent, origin: origin, reporter: reporter)
                        continue
                    }
                }
            }
        }
    }
    /// Join cancelled software owners only, never wait for physical movement or fresh pose feedback.
    private func joinCancelledControl() async {
        if let query = operation {
            do {
                // Retire a pending read before cancelling its owner: cancelling an on-wire query
                // directly would force the native SDK to disconnect its ambiguous reply stream.
                let session = try await link.beginLiveControl()
                query.cancel()
                await query.value
                await link.endLiveControl(session)
            } catch {
                query.cancel()
                await query.value
                // Explicit takeover ignores prior owner's execution errors.
            }
        }
        if let movement = motion { _ = await movement.result }
        while motion != nil || operation != nil, !Task.isCancelled { await Task.yield() }
    }
    public func setMotorVelocity(id: Int, value: Double) {
        guard (1...6).contains(id), value.isFinite else { return }
        if value == 0 {
            motorInputs[id - 1] = 0
            return
        }
        guard foreground, suspension == nil, state.canControl else {
            return
        }
        cancelTestSequence()
        pendingArmAction = nil
        aimGoal = nil
        if followingAim { liveTask?.cancel() }
        motorInputs[id - 1] = min(1, max(-1, value))
        startLiveControl()
    }
    private func cancelTestSequence() {
        manualRevision = UUID().uuidString
        pendingArmAction = nil
        settingsPlayback?.cancel()
    }
    public func stopMotorControl() {
        motorInputs = Array(repeating: 0, count: 6)
        aimGoal = nil
        cancelTestSequence()
    }
    private func startLiveControl() {
        guard liveTask == nil, let controller else { return }
        controlRevision = UUID().uuidString
        let revision = controlRevision
        let connectedGeneration = generation
        motion?.cancel()
        state.jogging = true
        let origin = manualOrigin
        let reporter = manualFailureReporter
        liveTask = Task {
            var failed = false
            let operation: @Sendable () async -> Void = { @MainActor [self] in
                var session: String?
                var nextMotorIndex = 0
                do {
                    if let playback = settingsPlayback { _ = await playback.result }
                    await joinCancelledControl()
                    try Task.checkCancellation()
                    let token = try await link.beginLiveControl()
                    session = token
                    if jogPlanner == nil {
                        jogPlanner = try NexArmJogPlanner(
                            positions: await controller.cachedJoints.count == 6
                                ? controller.cachedJoints : NexArmGesture.referenceHomeJoints)
                    }
                    var lastTick = ContinuousClock.now.advanced(by: .milliseconds(-30))
                    while true {
                        let tickStart = ContinuousClock.now
                        let duration = tickStart - lastTick
                        let elapsed =
                            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                        lastTick = tickStart
                        try Task.checkCancellation()
                        guard foreground, generation == connectedGeneration, state.canControl else {
                            throw CancellationError()
                        }
                        do {
                            let startIndex = nextMotorIndex
                            for offset in 0..<6 {
                                let index = (startIndex + offset) % 6
                                try Task.checkCancellation()
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
                                } else {
                                    nextMotorIndex = index
                                    break
                                }
                            }
                        }
                        for index in 0..<6 where abs(motorInputs[index]) <= 0.04 {
                            jogPlanner?.stop(id: index + 1)
                        }
                        if motorInputs.allSatisfy({ abs($0) <= 0.04 })
                            && motion == nil
                        {
                            break
                        }
                        try await Task.sleep(until: tickStart.advanced(by: .milliseconds(30)), clock: .continuous)
                    }
                } catch {
                    failed = !(error is CancellationError)
                    if failed {
                        await reportManualFailure(error, workerID: revision, origin: origin, reporter: reporter)
                    }
                }
                if let session { await link.endLiveControl(session) }
            }
            // Settings bypasses Agent resource arbitration; native admission remains shared.
            await operation()
            if revision == controlRevision {
                if failed {
                    motorInputs = Array(repeating: 0, count: 6)
                    if pendingArmAction == nil { cancelTestSequence() }
                }
                state.jogging = false
                liveTask = nil
                if !failed && foreground && generation == connectedGeneration && state.controlReady
                    && motorInputs.contains(where: { abs($0) > 0.04 })
                {
                    startLiveControl()
                }
            }
        }
    }
    /// Conversation/channel admission retains completion-based execution.
    public func shakeBase(cycles: Int, recordReport: @escaping @Sendable (ActionReport) async throws -> Void = { _ in })
        async throws
    {
        guard (1...3).contains(cycles) else { throw NexArmError.invalidMotion }
        try await runMotion(motors: Set(1...5), recordReport: recordReport) {
            try await $0.performGesture(.baseSway, repetitions: cycles)
        }
    }
    public func stopActions() async {
        pendingArmAction = nil
        settingsWorker?.cancel()
        settingsPlayback?.cancel()
        motion?.cancel()
        liveTask?.cancel()
        if let movement = motion { _ = await movement.result }
        await liveTask?.value
    }
    /// Gateway session cleanup owns Agent motion/aim only; it must not cancel Settings playback/jog.
    public func stopAgentActions() async {
        motion?.cancel()
        let aim = followingAim ? liveTask : nil
        if aim != nil {
            aimGoal = nil
            aim?.cancel()
        }
        if let movement = motion { _ = await movement.result }
        await aim?.value
    }
    public func resetArm(
        speed: Int = 1400, acceleration: Int = 30,
        recordReport: @escaping @Sendable (ActionReport) async throws -> Void = { _ in }
    ) async throws {
        try await runMotion(recordReport: recordReport) {
            try await $0.resetPosition(speed: speed, acceleration: acceleration)
        }
    }
    public func performGesture(
        _ gesture: NexArmGesture, repetitions: Int, speed: Int = 1400, acceleration: Int = 30,
        recordReport: @escaping @Sendable (ActionReport) async throws -> Void = { _ in }
    )
        async throws
    {
        try await runMotion(motors: gesture.lockedMotors, recordReport: recordReport) {
            try await $0.performGesture(gesture, repetitions: repetitions, speed: speed, acceleration: acceleration)
        }
    }
    /// Keeps only the latest aim. The manual-control loop streams it; this returns without waiting for the arm.
    public func aim(
        base: Double, pitch: Double, origin: NexArmControlOrigin? = nil,
        failed: @escaping @Sendable (NexArmControlFailure) async -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()
        guard foreground else { throw NexArmExecutionError.background }
        guard suspension == nil, motion == nil, operation == nil, cleanup == nil, settingsWorker == nil,
            pendingArmAction == nil
        else {
            throw NexArmExecutionError.busy
        }
        guard motorInputs.allSatisfy({ abs($0) <= 0.04 }) else { throw NexArmExecutionError.busy }
        guard state.phase == .connected, let controller else { throw NexArmExecutionError.disconnected }
        guard state.controlReady else {
            throw NexArmExecutionError.controlNotReady
        }
        guard liveTask == nil || followingAim else { throw NexArmExecutionError.busy }
        if !followingAim { forearmLeveler = NexArmForearmLeveler() }
        let positions = try NexArmJointCommand.positions(base: base, pitch: pitch)
        aimGoal = AimGoal(
            base: positions[0], lift: positions[1], elbow: forearmLeveler.elbow(forLift: positions[1]),
            pitch: positions[3])
        guard !followingAim else { return }
        let startup = startAimFollow(controller, origin: origin, failed: failed)
        let worker = liveTask
        try await withTaskCancellationHandler {
            var iterator = startup.makeAsyncIterator()
            guard try await iterator.next() != nil else { throw CancellationError() }
            try Task.checkCancellation()
        } onCancel: {
            worker?.cancel()
        }
    }
    /// Same 30 ms admission as a slider. Base, shoulder lift, elbow and wrist pitch move, one motor at a time in
    /// turn; wrist roll and the gripper stay put. A newer aim replaces the previous one.
    private func startAimFollow(
        _ controller: NexArmActionController, origin: NexArmControlOrigin?,
        failed reportFailure: @escaping @Sendable (NexArmControlFailure) async -> Void
    ) -> AsyncThrowingStream<Void, any Error> {
        let startup = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        guard liveTask == nil else {
            startup.continuation.finish(throwing: NexArmExecutionError.busy)
            return startup.stream
        }
        controlRevision = UUID().uuidString
        let revision = controlRevision
        let connectedGeneration = generation
        followingAim = true
        liveTask = Task {
            var failed = false
            var settled: AimGoal?
            var published = false
            defer { startup.continuation.finish() }
            let operation: @Sendable () async throws -> Void = { @MainActor [self] in
                var session: String?
                var nextAimIndex = 0
                do {
                    if let movement = motion { _ = await movement.result }
                    try Task.checkCancellation()
                    guard await trackingInputAvailable() else { throw CancellationError() }
                    try Task.checkCancellation()
                    try await validateAgentWriter(ResourceExecutionContext.held)
                    let token = try await link.beginLiveControl()
                    session = token
                    let joints = await controller.cachedJoints
                    if joints.count == 6 || jogPlanner == nil {
                        jogPlanner = try NexArmJogPlanner(
                            positions: joints.count == 6 ? joints : NexArmGesture.referenceHomeJoints)
                    }
                    try Task.checkCancellation()
                    guard foreground, generation == connectedGeneration, revision == controlRevision,
                        state.controlReady
                    else { throw CancellationError() }
                    startup.continuation.yield(())
                    startup.continuation.finish()
                    published = true
                    var idleSince: ContinuousClock.Instant?
                    var lastTick = ContinuousClock.now.advanced(by: .milliseconds(-30))
                    while true {
                        let tickStart = ContinuousClock.now
                        let duration = tickStart - lastTick
                        let elapsed =
                            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                        lastTick = tickStart
                        try Task.checkCancellation()
                        guard await trackingInputAvailable() else { throw CancellationError() }
                        try Task.checkCancellation()
                        guard foreground, generation == connectedGeneration, state.controlReady, aimGoal != nil else {
                            throw CancellationError()
                        }
                        guard let goal = aimGoal else { break }
                        var resting = true
                        // Base and wrist follow the image; shoulder and elbow are slower so the arm never sweeps.
                        let steps: [(id: Int, target: Int, speed: Double)] = [
                            (1, goal.base, NexArmJogPlanner.aimMaximumSpeed),
                            (2, goal.lift, NexArmJogPlanner.aimReachSpeed),
                            (3, goal.elbow, NexArmJogPlanner.aimReachSpeed),
                            (4, goal.pitch, NexArmJogPlanner.aimMaximumSpeed),
                        ]
                        let startIndex = nextAimIndex
                        for offset in 0..<steps.count {
                            let index = (startIndex + offset) % steps.count
                            let step = steps[index]
                            guard
                                let proposed = try jogPlanner?.approach(
                                    id: step.id, target: step.target, elapsed: elapsed, speedLimit: step.speed)
                            else { continue }
                            resting = false
                            guard let packet = proposed.packet else {
                                jogPlanner?.accept(proposed)
                                continue
                            }
                            try await validateAgentWriter(ResourceExecutionContext.held)
                            if try await link.sendLive(packet, session: token) {
                                jogPlanner?.accept(proposed)
                                nextAimIndex = (index + 1) % steps.count
                            } else {
                                nextAimIndex = index
                                break
                            }
                        }
                        if resting {
                            idleSince = idleSince ?? .now
                            if let idleSince, ContinuousClock.now - idleSince > .milliseconds(300) {
                                settled = aimGoal
                                break
                            }
                        } else {
                            idleSince = nil
                        }
                        try await Task.sleep(until: tickStart.advanced(by: .milliseconds(30)), clock: .continuous)
                    }
                } catch {
                    failed = true
                    startup.continuation.finish(throwing: error)
                    if revision == controlRevision { followingAim = false }
                    if published, !(error is CancellationError) {
                        await reportFailure(
                            .init(
                                workerID: revision, origin: origin,
                                code: ActionReport.code(for: error).rawValue, message: Self.message(error)))
                    }
                }
                if let session { await link.endLiveControl(session) }
                for id in 1...4 { jogPlanner?.stop(id: id) }
            }
            do {
                if let withMotorResources {
                    try await withMotorResources([1, 2, 3, 4], operation)
                } else {
                    try await operation()
                }
            } catch {
                failed = true
                startup.continuation.finish(throwing: error)
                if published, !(error is CancellationError) {
                    await reportFailure(
                        .init(
                            workerID: revision, origin: origin,
                            code: ActionReport.code(for: error).rawValue, message: Self.message(error)))
                }
            }
            // ResourceCoordinator.run has returned and released the old use before publishing idle/restarting.
            let restart =
                !failed && foreground && generation == connectedGeneration && revision == controlRevision
                && state.controlReady && aimGoal != nil && aimGoal != settled
            if revision == controlRevision {
                followingAim = false
                liveTask = nil
                if failed { aimGoal = nil }
                if restart {
                    _ = startAimFollow(controller, origin: origin, failed: reportFailure)
                } else if motorInputs.contains(where: { abs($0) > 0.04 }) {
                    startLiveControl()
                }
            }
        }
        return startup.stream
    }
    private func validateAgentWriter(_ resources: Set<ResourceID>) async throws {
        guard let permit = ResourceExecutionContext.permit else { return }
        do { try await permit.validate(resources) } catch {
            if error is CancellationError { throw error }
            throw NexArmExecutionError.resourceUnavailable(Self.message(error))
        }
    }
    private func runMotion(
        motors: Set<Int> = Set(1...5),
        recordReport: @escaping @Sendable (ActionReport) async throws -> Void,
        perform: @escaping @Sendable (NexArmActionController) async throws -> Void
    ) async throws {
        let required = Set(motors.map { ResourceID(rawValue: "nexarm.motor.\($0)") })
        if required.isSubset(of: ResourceExecutionContext.held), ResourceExecutionContext.permit != nil {
            try await validateAgentWriter(required)
        } else if let withMotorResources {
            try await withMotorResources(motors) {
                try await self.runMotion(motors: motors, recordReport: recordReport, perform: perform)
            }
            return
        }
        try Task.checkCancellation()
        guard foreground else { throw NexArmExecutionError.background }
        guard suspension == nil, operation == nil, cleanup == nil, motion == nil, liveTask == nil,
            settingsWorker == nil,
            pendingArmAction == nil
        else {
            throw NexArmExecutionError.busy
        }
        guard state.phase == .connected, let controller else { throw NexArmExecutionError.disconnected }
        guard state.controlReady else {
            throw NexArmExecutionError.controlNotReady
        }
        let token = UUID().uuidString
        let connectedGeneration = generation
        let revision = controlRevision
        motionID = token
        let task = Task {
            let resultRevision = await controller.motorResultRevision
            let outcome: Result<Void, any Error>
            do {
                try Task.checkCancellation()
                try await perform(controller)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            // Each invocation owns its report sink; no shared "last result" can be overwritten.
            if await controller.motorResultRevision != resultRevision,
                let report = try Self.report(await controller.motorResults)
            {
                switch outcome {
                case .success: try await recordReport(report)
                case .failure(let error): try await recordReport(report.recordingFailure(error))
                }
            }
            try outcome.get()
        }
        motion = task
        defer {
            motion = nil
            motionID = nil
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
            guard connectedGeneration == generation, revision == controlRevision else { throw NexArmError.disconnected }
            let sample = await controller.latestState
            try Task.checkCancellation()
            guard connectedGeneration == generation, revision == controlRevision else { throw NexArmError.disconnected }
            updateTelemetry(sample)
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private static func report(_ results: [NexArmMotorResult]) throws -> ActionReport? {
        guard !results.isEmpty else { return nil }
        return try ActionReport(
            entries: results.map { result in
                let code: ActionReport.Entry.Code?
                switch result.failure {
                case .targetNotReached: code = .targetNotReached
                case .timedOut: code = .timedOut
                case .feedbackLost: code = .feedbackLost
                case .disconnected: code = .disconnected
                case .sendingFailed: code = .sendingFailed
                case .admissionFailed: code = .admissionFailed
                case .feedbackFailed: code = .feedbackFailed
                case .cancelled: code = .cancelled
                case nil: code = nil
                }
                var details = ["motor": String(result.motor), "target": String(result.target)]
                if let observed = result.observed { details["observed"] = String(observed) }
                return .init(
                    path: "step.\(result.step).motor.\(result.motor)",
                    status: result.failure == .cancelled
                        ? (result.started ? .cancelled : .notStarted) : (result.failure == nil ? .succeeded : .failed),
                    code: code, details: details)
            })
    }
    public func moveMotor(
        id: Int, target: Int?, speed: Int, acceleration: Int,
        recordReport: @escaping @Sendable (ActionReport) async throws -> Void = { _ in }
    ) async throws {
        let options = try NexArmMotorOptions(speed: speed, acceleration: acceleration)
        let completion = try NexArmMotorCompletion()
        try await runMotion(motors: [id], recordReport: recordReport) { controller in
            if let target {
                try await controller.moveMotor(id: id, target: target, options: options, completion: completion)
            } else {
                try await controller.resetMotor(id: id, options: options, completion: completion)
            }
        }
    }
    private static func message(_ error: any Error) -> String {
        return ActionReport.description(for: error)
    }
}
