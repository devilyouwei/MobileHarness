import ActionRuntime
import Actions
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
    case incomplete([Int])
    case resourceBusy
    case resourceUnavailable(String)
    public var actionExecutionFailure: ActionFailure {
        let identifier: String
        switch self {
        case .disconnected: identifier = "disconnected"
        case .busy: identifier = "busy"
        case .resourceBusy, .resourceUnavailable: identifier = "resourceUnavailable"
        case .background: identifier = "background"
        case .posture: identifier = "invalidPose"
        case .unverified: identifier = "unconfirmed"
        case .controlNotReady: identifier = "controlNotReady"
        case .feedbackTimeout: identifier = "feedbackTimeout"
        case .completionTimeout, .incomplete: identifier = "completionTimeout"
        }
        return ActionFailure(rawValue: identifier)
    }
    public var actionReportCode: ActionReport.Entry.Code {
        switch self {
        case .feedbackTimeout: .feedbackLost
        case .disconnected: .disconnected
        case .completionTimeout, .incomplete: .targetNotReached
        case .posture: .invalidArguments
        case .busy, .controlNotReady, .background, .resourceBusy, .resourceUnavailable: .unavailable
        case .unverified: .handlerFailed
        }
    }
    public var errorDescription: String? {
        switch self {
        case .disconnected: "机械臂未连接，请到设置 → 蓝牙外设连接 NexArm"
        case .busy: "机械臂正在处理上一项操作，请稍后重试"
        case .resourceBusy: "电机控制资源正在被其他操作占用，请稍后重试"
        case .resourceUnavailable(let reason): "电机控制资源不可用：\(reason)"
        case .background: "请保持应用在前台后再控制机械臂"
        case .posture: "当前姿态不适合这个动作，请先调整机械臂姿态后重试"
        case .unverified: "动作未确认完成，可刷新状态或继续操作"
        case .feedbackTimeout: "机械臂连接不稳定：位置反馈丢失，动作已中断"
        case .completionTimeout: "动作未在期限内到位"
        case .incomplete(let segments): "第\(segments.map(String.init).joined(separator: "、"))段长期未达到目标位，已继续执行其余段"
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
    private var controlRevision = UUID()
    private var manualRevision = UUID()
    private var pendingArmAction: BluetoothArmAction?
    private var settingsWorker: Task<Void, Never>?
    private var settingsPlayback: Task<Void, any Error>?
    public var withMotorResources:
        (@Sendable (Set<Int>, @escaping @Sendable () async throws -> Void) async throws -> Void)?
    public var trackingAvailable: Bool {
        state.controlReady && settingsWorker == nil && pendingArmAction == nil && !state.jogging
            && motion == nil && operation == nil && cleanup == nil
    }
    public private(set) var lastActionReport: ActionReport?
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
    private var recovery: Task<Void, Never>?
    private var recoveryID = UUID()
    private var recoveryPending = false
    private var recoveryNeedsUser = false
    private var recoveryAttempts = 0
    private var recoveryEpisode = UUID()
    private var recoveryStarted: ContinuousClock.Instant?
    private var readySince: ContinuousClock.Instant?
    private var recoveryCause = BluetoothRecoveryCause.resume
    private var connectionError: (any Error)?
    private var latestLinkSnapshot = NexArmBluetoothSnapshot() {
        didSet {
            switch latestLinkSnapshot.phase {
            case .connected: state.transportStatus = "已连接"
            case .connecting: state.transportStatus = "正在连接"
            case .disconnecting: state.transportStatus = "正在断开"
            case .disconnected: state.transportStatus = "已断开"
            }
            switch latestLinkSnapshot.power {
            case .poweredOn: state.availability = .available
            case .poweredOff: state.availability = .poweredOff
            case .unauthorized: state.availability = .denied
            case .unsupported: state.availability = .unsupported
            case .unknown, .resetting: state.availability = .unknown
            }
        }
    }
    private var incidentDevices: [UUID] = []

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
        if value.revision != 0, value.revision <= latestLinkSnapshot.revision { return }
        let previousPower = latestLinkSnapshot.power
        latestLinkSnapshot = value
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
            state.nearby = value.devices.sorted(by: BluetoothPresentation.discoveryOrder).compactMap {
                guard let name = BluetoothPresentation.deviceName($0.name) else {
                    return nil
                }
                return .init(id: $0.id, name: name)
            }
        } else {
            state.nearby = []
        }
        if let selected = value.selected, state.selected?.id == selected.id {
            state.selected = .init(id: selected.id, name: BluetoothPresentation.deviceName(selected.name) ?? "未命名设备")
        }
        if let failure = value.failure, operation == nil, cleanup == nil, state.selected != nil {
            state.error = BluetoothPresentation.failure(failure)
        }
        if discoveryVisible && value.discoveryLimitReached { state.notice = "附近设备较多，请靠近机械臂后重新搜索" }
        // Connection/verification tasks own their failures. Repeated health snapshots cannot spawn another worker.
        if controller != nil, operation == nil, cleanup == nil {
            if value.phase == .disconnecting || value.phase == .disconnected {
                requestRecovery(cause(for: value), snapshot: value)
            } else if value.phase == .connected, !value.feedbackHealthy, state.controlValidated {
                state.controlValidated = false
                requestRecovery(cause(for: value, fallback: .feedback), snapshot: value)
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
    public func connect(_ id: UUID) {
        guard recovery == nil, cleanup == nil else {
            state.error = "正在恢复连接，请等待完成或先断开"
            recordIncident("请求被拒绝", message: state.error ?? "", deviceID: id)
            return
        }
        resetRecoveryBudget()
        recoveryCause = .manual
        state.recoveryStage = .idle
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
        connectionError = nil
        if !automatically { reconnectEnabled = false }
        state.selected = device
        state.nearby = []
        state.scanning = false
        state.joints = []
        jogPlanner = nil
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
                let candidate = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
                controller = candidate
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [self] in
                        try await self.verifyConnection(
                            device: device, candidate: candidate, token: token, indicate: !automatically)
                    }
                    group.addTask {
                        try await Task.sleep(for: BluetoothRecoveryPolicy.verificationTimeout)
                        throw BluetoothRecoveryError.verificationTimeout
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } catch {
                guard token == generation else { return }
                let failed = await link.status()
                guard token == generation else { return }
                connectionError = error
                latestLinkSnapshot = failed
                state.controlValidated = false
                state.error = failed.failure.map(BluetoothPresentation.failure) ?? state.error ?? Self.message(error)
                recordIncident("连接/验证失败", message: state.error ?? Self.message(error), deviceID: id)
                state.phase = failed.phase == .connected ? .connected : .failed
                if !automatically, !(error is CancellationError) {
                    // Explicit device selection authorizes bounded recovery; no motion is replayed.
                    reconnectEnabled = true
                    requestRecovery(
                        cause(for: failed, fallback: .verification), snapshot: failed,
                        retry: BluetoothRecoveryPolicy.canRetry(error))
                }
            }
        }
    }
    private func verifyConnection(
        device: BluetoothDeviceRow, candidate: NexArmActionController, token: UUID, indicate: Bool = true
    ) async throws {
        state.phase = .verifying
        if recovery != nil { state.recoveryStage = .verifying }
        state.controlValidated = false
        state.error = nil
        state.notice = nil
        state.notice = "正在读取机械臂位置并验证连接…"
        do {
            _ = try await candidate.verifyCompatibility()
        } catch {
            if token == generation, !(error is CancellationError) {
                let sample = await candidate.latestState
                let telemetry = sample.pose.map(String.init).joined(separator: ", ")
                state.error = "连接验证失败（位置读取/协议检查）：\(Self.message(error))；设备坐标 [\(telemetry)]"
            }
            throw error
        }
        state.notice = "正在准备机械臂动作映射…"
        do {
            _ = try await candidate.prepareArmControl()
        } catch {
            if token == generation, !(error is CancellationError) {
                state.error = "连接验证失败（预设动作映射）：\(Self.message(error))"
            }
            throw error
        }
        try Task.checkCancellation()
        guard foreground, token == generation else { throw CancellationError() }
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
                guard
                    error as? NexArmActionError == .uncertainMotion
                        || error as? NexArmActionError == .moving
                        || error as? NexArmError == .invalidMotion
                else { throw error }
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
        let verified = await link.status()
        try Task.checkCancellation()
        guard token == generation, foreground, verified.phase == .connected else { throw NexArmError.disconnected }
        guard verified.feedbackHealthy else { throw NexArmError.feedbackLost }
        controller = candidate
        state.phase = .connected
        state.controlValidated = true
        readySince = .now
        state.error = nil
        state.nearby = []
        state.scanning = false
        state.notice = indicate ? "已连接，可以返回对话控制机械臂" : "已自动恢复连接，可以继续控制机械臂"
    }
    public func disconnect() { disconnect(preserveReconnect: false) }
    private func disconnect(preserveReconnect: Bool, cancelRecovery: Bool = true) {
        if cancelRecovery {
            recoveryID = UUID()
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
        controlRevision = UUID()
        readySince = nil
        if !preserveReconnect {
            recoveryPending = false
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
        state.pose = []
        state.sampledAt = nil
        state.controlValidated = false
        operation?.cancel()
        motion?.cancel()
        let pending = operation
        let movement = motion
        let streaming = liveTask
        let settings = settingsWorker
        state.phase = .disconnecting
        cleanup = Task {
            defer { cleanup = nil }
            // Close native admission first so cancellation can unblock any old request.
            await link.disconnect()
            await pending?.value
            await streaming?.value
            // A fenced aim owner intentionally avoids publishing state; release its completed task here.
            liveTask = nil
            await settings?.value
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
            state.phase =
                state.recoveryStage == .failed ? .failed : (closed.phase == .disconnected ? .idle : .disconnecting)
            if let failure = closed.failure { state.error = BluetoothPresentation.failure(failure) }
            state.controlValidated = false
            state.executing = false
            state.refreshing = false
            state.jogging = false
            state.testing = false
            state.resetting = false
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
                    state.motionStatus = nil
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
        state.motionStatus = nil
        state.notice = nil
        disconnect()
    }
    public func setForeground(_ active: Bool) {
        let changed = foreground != active
        foreground = active
        if !active {
            if let id = state.selected?.id {
                recordIncident("暂停", message: "应用进入后台，已停止控制与恢复", deviceID: id)
            }
            disconnect(preserveReconnect: true)
        } else if changed {
            // Paused/unavailable time does not consume the active recovery time window or refill attempts.
            recoveryStarted = nil
            scheduleReconnect()
        }
    }
    private func scheduleReconnect() {
        guard foreground, !recoveryNeedsUser, recovery == nil else { return }
        let identity = recoveryID
        recovery = Task { [self] in
            do { try await restore() } catch {
                state.error = "设备记录读取失败：\(Self.message(error))"
            }
            await cleanup?.value
            guard identity == recoveryID, !Task.isCancelled else { return }
            recovery = nil
            guard foreground, reconnectEnabled, controller == nil else { return }
            requestRecovery(.resume, snapshot: await link.status())
        }
    }

    private func cause(
        for snapshot: NexArmBluetoothSnapshot, fallback: BluetoothRecoveryCause = .disconnected
    ) -> BluetoothRecoveryCause {
        if snapshot.queriesQuarantined { return .query }
        if case .responseTimeout = snapshot.failure { return .query }
        if snapshot.power != .poweredOn { return .power }
        return snapshot.failure == nil ? fallback : .transport
    }
    private func resetRecoveryBudget() {
        recoveryAttempts = 0
        recoveryNeedsUser = false
        recoveryEpisode = UUID()
        recoveryStarted = nil
        readySince = nil
        state.recoveryAttempt = 0
    }
    private func recordIncident(
        _ stage: String, message: String, deviceID: UUID? = nil, cause: BluetoothRecoveryCause? = nil
    ) {
        guard let id = deviceID ?? state.selected?.id ?? state.remembered?.id else { return }
        incidentDevices.removeAll { $0 == id }
        incidentDevices.append(id)
        if incidentDevices.count > 4 {
            let removed = incidentDevices.removeFirst()
            state.incidents.removeAll { $0.deviceID == removed }
        }
        let elapsed = recoveryStarted.map { ContinuousClock.now - $0 } ?? .zero
        let traffic = latestLinkSnapshot.traffic
        let details = [
            "底层错误：\(String(describing: latestLinkSnapshot.failure))；查询隔离：\(latestLinkSnapshot.queriesQuarantined)",
            "蓝牙：\(latestLinkSnapshot.phase)；反馈健康：\(latestLinkSnapshot.feedbackHealthy)",
            "发送 \(traffic.sentPackets) 包 / \(traffic.sentBytes) 字节",
            "限速等待 \(traffic.pacingDeferrals) 次；系统阻塞 \(traffic.systemDeferrals) 次",
            "收到通知 \(traffic.notificationBytes) 字节；有效位置样本 \(traffic.feedbackSamples)",
            "通知间隔 \(traffic.notificationGapMilliseconds) ms；反馈间隔 \(traffic.feedbackGapMilliseconds) ms",
            "位置 [\(state.pose.map(String.init).joined(separator: ", "))]",
        ]
        let entry = BluetoothIncident(
            episodeID: recoveryEpisode, deviceID: id, cause: (cause ?? recoveryCause).rawValue, stage: stage,
            message: message, attempt: recoveryAttempts,
            elapsedSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            details: details)
        let indices = state.incidents.indices.filter { state.incidents[$0].deviceID == id }
        if indices.count >= 32, let oldest = indices.last { state.incidents.remove(at: oldest) }
        state.incidents.insert(entry, at: 0)
    }
    public func clearIncidents(_ id: UUID) {
        state.incidents.removeAll { $0.deviceID == id }
        incidentDevices.removeAll { $0 == id }
    }
    public func reconnect(_ id: UUID) {
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
        if recovery != nil { return }
        if let readySince, ContinuousClock.now - readySince >= BluetoothRecoveryPolicy.stableInterval {
            resetRecoveryBudget()
        }
        readySince = nil
        recoveryStarted = recoveryStarted ?? .now
        recoveryCause = cause
        recoveryPending = false
        recoveryID = UUID()
        let identity = recoveryID
        state.recoveryDeviceID = device.id
        state.recoveryStage = .cleaning
        recordIncident("异常/恢复请求", message: cause.rawValue)
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
            recordIncident("清理完成", message: "旧任务已结束，旧连接已关闭")
            guard retry else {
                finishRecoveryFailure(connectionError ?? NexArmError.invalidMotion)
                return
            }
            while recoveryAttempts < BluetoothRecoveryPolicy.maximumAttempts {
                guard identity == recoveryID, !Task.isCancelled, foreground, reconnectEnabled else { return }
                var native = await link.status()
                if native.power == .unknown || native.power == .resetting {
                    do { try await link.scan() } catch {
                        recordIncident("蓝牙初始化", message: Self.message(error))
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
                    recordIncident("等待蓝牙", message: state.notice ?? "")
                    return
                }
                if let started = recoveryStarted,
                    ContinuousClock.now - started >= BluetoothRecoveryPolicy.episodeTimeout
                {
                    finishRecoveryFailure(BluetoothRecoveryError.episodeTimeout)
                    return
                }
                recoveryAttempts += 1
                state.recoveryAttempt = recoveryAttempts
                state.recoveryStage = .waiting
                state.notice = "等待重新连接，第 \(recoveryAttempts)/3 次"
                recordIncident("等待重试", message: state.notice ?? "")
                do { try await Task.sleep(for: BluetoothRecoveryPolicy.delay(attempt: recoveryAttempts)) } catch {
                    return
                }
                guard identity == recoveryID, !Task.isCancelled, foreground, reconnectEnabled else { return }
                state.recoveryStage = .connecting
                connect(device.id, automatically: true)
                await operation?.value
                guard identity == recoveryID, !Task.isCancelled else { return }
                native = await link.status()
                latestLinkSnapshot = native
                if state.controlValidated, native.phase == .connected, native.feedbackHealthy {
                    state.recoveryStage = .idle
                    state.error = nil
                    state.notice = "连接与控制已恢复；中断动作未重放"
                    recordIncident("恢复成功", message: state.notice ?? "")
                    return
                }
                let failure = connectionError ?? NexArmError.disconnected
                state.recoveryStage = .cleaning
                disconnect(preserveReconnect: true, cancelRecovery: false)
                await cleanup?.value
                guard identity == recoveryID, !Task.isCancelled else { return }
                native = await link.status()
                latestLinkSnapshot = native
                guard native.phase == .disconnected else {
                    finishRecoveryFailure(BluetoothRecoveryError.disconnectUnconfirmed)
                    return
                }
                guard BluetoothRecoveryPolicy.canRetry(failure) else {
                    finishRecoveryFailure(failure)
                    return
                }
            }
            finishRecoveryFailure(connectionError ?? NexArmError.disconnected)
        }
    }
    private func handleControlFailure(_ error: any Error, stage: String) {
        guard !(error is CancellationError) else { return }
        recordIncident(stage, message: Self.message(error))
        let cause: BluetoothRecoveryCause
        if error as? NexArmError == .feedbackLost || error as? BluetoothWorkflowError == .feedbackTimeout {
            cause = .feedback
        } else if error as? NexArmError == .timeout {
            cause = .congestion
        } else if error as? NexArmError == .disconnected {
            cause = .disconnected
        } else {
            return
        }
        requestRecovery(cause, snapshot: latestLinkSnapshot)
    }

    private func finishRecoveryFailure(_ error: any Error) {
        recoveryPending = false
        recoveryNeedsUser = true
        state.controlValidated = false
        state.recoveryStage = .failed
        state.phase = .failed
        let description = error is BluetoothRecoveryError ? Self.message(error) : (state.error ?? Self.message(error))
        state.error = "恢复未完成：\(description)"
        state.notice = "请检查设备后手动重新连接"
        recordIncident("恢复停止", message: state.error ?? "")
    }
    public func waitUntilIdle() async {
        repeat {
            await discovery?.value
            await operation?.value
            await cleanup?.value
            await recovery?.value
            await liveTask?.value
            await settingsWorker?.value
            await Task.yield()
        } while discovery != nil || operation != nil || cleanup != nil || recovery != nil
            || liveTask != nil || settingsWorker != nil
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
        guard foreground, recovery == nil, state.phase == .connected, !state.executing, liveTask == nil,
            operation == nil,
            cleanup == nil, let controller
        else { return }
        let token = generation
        let revision = controlRevision
        state.refreshing = true
        let task = Task { @MainActor in
            defer { state.refreshing = false }
            do {
                let sample = try await controller.recoverState()
                _ = try await controller.verifyCompatibility()
                _ = try await controller.prepareArmControl()
                try Task.checkCancellation()
                guard token == generation, revision == controlRevision, state.phase == .connected else { return }
                updateTelemetry(sample)
                state.controlValidated = true
                state.error = nil
                state.notice = "控制反馈验证通过"
            } catch {
                if token == generation, revision == controlRevision, !Task.isCancelled, !(error is CancellationError) {
                    let failed = await link.status()
                    guard token == generation, revision == controlRevision else { return }
                    latestLinkSnapshot = failed
                    state.error = Self.message(error)
                    state.controlValidated = false
                    recordIncident("手动验证失败", message: Self.message(error))
                    requestRecovery(
                        cause(for: latestLinkSnapshot, fallback: .verification), snapshot: latestLinkSnapshot,
                        retry: BluetoothRecoveryPolicy.canRetry(error))
                }
            }
        }
        operation = task
        await task.value
        operation = nil
    }
    public func tryAction(_ action: BluetoothArmAction) {
        guard foreground, state.controlReady else {
            state.error = Self.message(
                state.phase == .connected ? BluetoothWorkflowError.controlNotReady : .disconnected)
            recordIncident("发送被拒绝", message: state.error ?? "控制未就绪，未发送动作")
            return
        }
        manualRevision = UUID()
        motorInputs = Array(repeating: 0, count: 6)
        aimGoal = nil
        liveTask?.cancel()
        motion?.cancel()
        settingsPlayback?.cancel()
        state.error = nil
        pendingArmAction = action  // Capacity one; Settings explicitly replaces its previous request.
        guard settingsWorker == nil else { return }
        settingsWorker = Task {
            defer {
                settingsWorker = nil
                state.testing = false
                state.resetting = false
            }
            while let action = pendingArmAction {
                let intent = manualRevision
                pendingArmAction = nil
                await liveTask?.value
                await joinCancelledControl()
                if intent != manualRevision { continue }
                guard !Task.isCancelled, foreground, state.controlReady, let controller else { return }
                let connectedGeneration = generation
                state.error = nil
                state.testing = action != .reset
                state.resetting = action == .reset
                state.motionStatus = "正在发送\(action.title)…"
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
                    let session = try await link.beginLiveControl()
                    do {
                        let measured = await controller.cachedJoints
                        var estimate = jogPlanner?.targets.map { Int($0) } ?? measured
                        try await plan.submit { @MainActor [self] packet in
                            try Task.checkCancellation()
                            guard foreground, generation == connectedGeneration, manualRevision == intent,
                                state.controlReady
                            else {
                                throw CancellationError()
                            }
                            let accepted = try await link.sendLive(packet, session: session)
                            if accepted {
                                estimate = try NexArmArmPlan.applying(packet, to: estimate)
                                jogPlanner = try NexArmJogPlanner(positions: estimate)
                            }
                            return accepted
                        }
                        await link.endLiveControl(session)
                    } catch {
                        await link.endLiveControl(session)
                        throw error
                    }
                }
                settingsPlayback = playback
                let result = await playback.result
                settingsPlayback = nil
                guard generation == connectedGeneration else { return }
                switch result {
                case .success:
                    if pendingArmAction == nil { state.motionStatus = "已发送\(action.title)指令" }
                case .failure(let error):
                    if pendingArmAction == nil, !Task.isCancelled, !(error is CancellationError) {
                        state.error = Self.message(error)
                        handleControlFailure(error, stage: "手动动作发送失败")
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
                if !(error is CancellationError) { handleControlFailure(error, stage: "手动接管失败") }
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
        guard foreground, state.controlReady else {
            state.error = Self.message(
                state.phase == .connected ? BluetoothWorkflowError.controlNotReady : .disconnected)
            recordIncident("发送被拒绝", message: state.error ?? "控制未就绪，未发送电机指令")
            return
        }
        cancelTestSequence()
        pendingArmAction = nil
        aimGoal = nil
        if followingAim { liveTask?.cancel() }
        state.resetting = false
        motorInputs[id - 1] = min(1, max(-1, value))
        startLiveControl()
    }
    private func cancelTestSequence() {
        manualRevision = UUID()
        pendingArmAction = nil
        settingsPlayback?.cancel()
        if state.testing || state.resetting { motion?.cancel() }
        state.testing = false
        state.resetting = false
    }
    public func stopMotorControl() {
        motorInputs = Array(repeating: 0, count: 6)
        aimGoal = nil
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
            var failed = false
            let operation: @Sendable () async -> Void = { @MainActor [self] in
                var session: UUID?
                var nextMotorIndex = 0
                do {
                    if let playback = settingsPlayback { _ = await playback.result }
                    await joinCancelledControl()
                    try Task.checkCancellation()
                    let token = try await link.beginLiveControl()
                    session = token
                    if jogPlanner == nil {
                        jogPlanner = try NexArmJogPlanner(positions: await controller.cachedJoints)
                    }
                    var stalledSince: ContinuousClock.Instant?
                    var lastTick = ContinuousClock.now.advanced(by: .milliseconds(-30))
                    while true {
                        let tickStart = ContinuousClock.now
                        let duration = tickStart - lastTick
                        let elapsed =
                            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                        lastTick = tickStart
                        try Task.checkCancellation()
                        guard foreground, generation == connectedGeneration, state.controlReady else {
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
                        if let stalledSince, ContinuousClock.now - stalledSince > .seconds(2) {
                            throw NexArmError.timeout
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
                    if !(error is CancellationError), generation == connectedGeneration {
                        state.error = Self.message(error)
                        handleControlFailure(error, stage: "控制循环退出")
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
                if state.motionStatus == "手动控制中" { state.motionStatus = "手动控制已结束" }
                if !failed && foreground && generation == connectedGeneration && state.controlReady
                    && motorInputs.contains(where: { abs($0) > 0.04 })
                {
                    startLiveControl()
                }
            }
        }
    }
    /// Conversation/channel admission retains completion-based execution.
    public func shakeBase(cycles: Int) async throws {
        guard (1...3).contains(cycles) else { throw NexArmError.invalidMotion }
        try await runMotion(label: "左右晃动 \(cycles) 次") { try await $0.performGesture(.baseSway, repetitions: cycles) }
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
    public func resetArm(speed: Int = 1400, acceleration: Int = 30) async throws {
        try await runMotion(label: "整臂归位", returnsHome: false) {
            try await $0.resetPosition(speed: speed, acceleration: acceleration)
        }
    }
    public func performGesture(_ gesture: NexArmGesture, repetitions: Int, speed: Int = 1400, acceleration: Int = 30)
        async throws
    {
        try await runMotion(label: gesture.displayName, motors: gesture.lockedMotors) {
            try await $0.performGesture(gesture, repetitions: repetitions, speed: speed, acceleration: acceleration)
        }
    }
    /// Keeps only the latest aim. The manual-control loop streams it; this returns without waiting for the arm.
    public func aim(base: Double, pitch: Double) async throws {
        try Task.checkCancellation()
        guard foreground else { throw BluetoothWorkflowError.background }
        guard motion == nil, operation == nil, cleanup == nil, settingsWorker == nil, pendingArmAction == nil else {
            throw BluetoothWorkflowError.busy
        }
        guard motorInputs.allSatisfy({ abs($0) <= 0.04 }) else { throw BluetoothWorkflowError.busy }
        guard state.phase == .connected, let controller else { throw BluetoothWorkflowError.disconnected }
        guard state.controlReady else {
            recordIncident("发送被拒绝", message: "控制未验证或恢复处理中，未发送动作")
            throw BluetoothWorkflowError.controlNotReady
        }
        guard liveTask == nil || followingAim else { throw BluetoothWorkflowError.busy }
        if !followingAim { forearmLeveler = NexArmForearmLeveler() }
        let positions = try NexArmJointCommand.positions(base: base, pitch: pitch)
        aimGoal = AimGoal(
            base: positions[0], lift: positions[1], elbow: forearmLeveler.elbow(forLift: positions[1]),
            pitch: positions[3])
        state.motionStatus = "正在瞄准"
        guard !followingAim else { return }
        let startup = startAimFollow(controller)
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
    private func startAimFollow(_ controller: NexArmActionController) -> AsyncThrowingStream<Void, any Error> {
        let startup = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        guard liveTask == nil else {
            startup.continuation.finish(throwing: BluetoothWorkflowError.busy)
            return startup.stream
        }
        controlRevision = UUID()
        let revision = controlRevision
        let connectedGeneration = generation
        followingAim = true
        liveTask = Task {
            var failed = false
            var settled: AimGoal?
            defer { startup.continuation.finish() }
            let operation: @Sendable () async throws -> Void = { @MainActor [self] in
                var session: UUID?
                var nextAimIndex = 0
                do {
                    if let movement = motion { _ = await movement.result }
                    try Task.checkCancellation()
                    let token = try await link.beginLiveControl()
                    session = token
                    let joints = await controller.cachedJoints
                    if joints.count == 6 {
                        jogPlanner = try NexArmJogPlanner(positions: joints)
                    } else if jogPlanner == nil {
                        throw NexArmError.invalidMotion
                    }
                    try Task.checkCancellation()
                    guard foreground, generation == connectedGeneration, revision == controlRevision,
                        state.controlReady
                    else { throw CancellationError() }
                    state.error = nil
                    startup.continuation.yield(())
                    startup.continuation.finish()
                    var stalledSince: ContinuousClock.Instant?
                    var idleSince: ContinuousClock.Instant?
                    var lastTick = ContinuousClock.now.advanced(by: .milliseconds(-30))
                    while true {
                        let tickStart = ContinuousClock.now
                        let duration = tickStart - lastTick
                        let elapsed =
                            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                        lastTick = tickStart
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
                            if try await link.sendLive(packet, session: token) {
                                jogPlanner?.accept(proposed)
                                nextAimIndex = (index + 1) % steps.count
                                stalledSince = nil
                            } else {
                                stalledSince = stalledSince ?? .now
                                nextAimIndex = index
                                break
                            }
                        }
                        if let stalledSince, ContinuousClock.now - stalledSince > .seconds(2) {
                            throw NexArmError.timeout
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
                    if !(error is CancellationError), generation == connectedGeneration {
                        state.error = Self.message(error)
                        handleControlFailure(error, stage: "控制循环退出")
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
                if generation == connectedGeneration, revision == controlRevision, !(error is CancellationError) {
                    state.error = Self.message(error)
                    recordIncident("控制启动失败", message: Self.message(error), cause: .resources)
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
                if state.motionStatus == "正在瞄准" { state.motionStatus = "瞄准跟随已停下" }
                if restart {
                    _ = startAimFollow(controller)
                } else if motorInputs.contains(where: { abs($0) > 0.04 }) {
                    startLiveControl()
                }
            }
        }
        return startup.stream
    }
    private func runMotion(
        label: String, returnsHome: Bool = true, motors: Set<Int> = Set(1...5),
        perform: @escaping @Sendable (NexArmActionController) async throws -> Void
    ) async throws {
        let required = Set(motors.map { ResourceID(rawValue: "nexarm.motor.\($0)") })
        if let withMotorResources, !required.isSubset(of: ResourceExecutionContext.held) {
            let admissionGeneration = generation
            do {
                try await withMotorResources(motors) {
                    try await self.runMotion(label: label, returnsHome: returnsHome, motors: motors, perform: perform)
                }
            } catch {
                switch error as? BluetoothWorkflowError {
                case .resourceBusy, .resourceUnavailable:
                    if generation == admissionGeneration {
                        state.error = Self.message(error)
                        recordIncident("动作资源被拒绝", message: Self.message(error), cause: .resources)
                    }
                default: break
                }
                throw error
            }
            return
        }
        lastActionReport = nil
        try Task.checkCancellation()
        guard foreground else { throw BluetoothWorkflowError.background }
        guard operation == nil, cleanup == nil, motion == nil, liveTask == nil, settingsWorker == nil,
            pendingArmAction == nil
        else {
            throw BluetoothWorkflowError.busy
        }
        guard state.phase == .connected, let controller else { throw BluetoothWorkflowError.disconnected }
        guard state.controlReady else {
            recordIncident("发送被拒绝", message: "控制未验证或恢复处理中，未发送动作")
            throw BluetoothWorkflowError.controlNotReady
        }
        let token = UUID()
        let connectedGeneration = generation
        let revision = controlRevision
        lastActionReport = nil
        motionID = token
        state.executing = true
        state.error = nil
        state.motionStatus = "正在\(label)…"
        var failureDetail: NexArmMotionFailure?
        let task = Task {
            do {
                try Task.checkCancellation()
                try await perform(controller)
                lastActionReport = try Self.report(await controller.motorResults)
            } catch {
                lastActionReport = try Self.report(await controller.motorResults)
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
            handleControlFailure(error, stage: "动作退出")
            if error as? NexArmError == .feedbackLost {
                state.controlValidated = false
                state.error = BluetoothWorkflowError.feedbackTimeout.localizedDescription
                throw BluetoothWorkflowError.feedbackTimeout
            }
            if case .targetsNotReached(let segments) = error as? NexArmActionError {
                let failure = BluetoothWorkflowError.incomplete(segments)
                state.error = failure.localizedDescription
                throw failure
            }
            if error as? NexArmActionError == .uncertainMotion {
                // Completion uncertainty is not a disconnected transport. Keep the owner so
                // refresh/the next explicit request can revalidate stationary feedback.
                state.motionStatus = "动作未确认完成"
                switch failureDetail {
                case .sending:
                    state.error = "动作指令未能发送，正在恢复连接"
                    requestRecovery(.transport, snapshot: latestLinkSnapshot)
                case .feedbackTimeout: state.error = "动作反馈超时，结果未知，可重新发起动作或重置"
                case .completionTimeout: state.error = "动作未在期限内到位，可重新发起动作或重置"
                case nil: break
                }
            }
            if error as? NexArmError == .invalidMotion { throw BluetoothWorkflowError.posture }
            if error as? NexArmActionError == .uncertainMotion {
                if failureDetail == .feedbackTimeout { throw BluetoothWorkflowError.feedbackTimeout }
                if failureDetail == .completionTimeout { throw BluetoothWorkflowError.completionTimeout }
                throw BluetoothWorkflowError.unverified
            }
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
    public func moveMotor(id: Int, target: Int?, speed: Int, acceleration: Int) async throws {
        lastActionReport = nil
        let options = try NexArmMotorOptions(speed: speed, acceleration: acceleration)
        let completion = try NexArmMotorCompletion()
        try await runMotion(label: "舵机\(id)", returnsHome: false, motors: [id]) { controller in
            if let target {
                try await controller.moveMotor(id: id, target: target, options: options, completion: completion)
            } else {
                try await controller.resetMotor(id: id, options: options, completion: completion)
            }
        }
    }
    private static func message(_ error: any Error) -> String {
        if let error = error as? BluetoothWorkflowError { return error.localizedDescription }
        if error is CancellationError { return "操作已取消" }
        switch error as? NexArmActionError {
        case .targetsNotReached(let segments): return BluetoothWorkflowError.incomplete(segments).localizedDescription
        case .motionTimedOut: return "持续运动超过预计执行上限，已记录超时"
        case .moving: return "机械臂尚未静止，请稍后重试"
        case .uncertainMotion: return BluetoothWorkflowError.unverified.localizedDescription
        default: break
        }
        switch error as? NexArmError {
        case .feedbackLost: return BluetoothWorkflowError.feedbackTimeout.localizedDescription
        case .firmwareUnavailable: return "设备验证未完成，请重新连接"
        case .unsupportedFirmware: return "当前固件尚未验证，暂不能控制这台机械臂"
        case .invalidMotion: return BluetoothWorkflowError.posture.localizedDescription
        case .busy: return BluetoothWorkflowError.busy.localizedDescription
        case .disconnected: return BluetoothWorkflowError.disconnected.localizedDescription
        case .timeout: return "设备响应超时，请检查距离、供电及 Wonderbot 是否已断开"
        default: break
        }
        switch error as? NexArmBluetoothError {
        case .unavailable: return "蓝牙不可用，请检查系统蓝牙和应用权限"
        case .unknownDevice: return "未找到设备，请重新搜索"
        case .incompatibleService: return "设备的蓝牙服务不兼容，无法连接"
        default: return "操作失败：\(error.localizedDescription)"
        }
    }
}
