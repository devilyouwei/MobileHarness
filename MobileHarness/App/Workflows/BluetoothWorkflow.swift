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
public enum BluetoothWorkflowError: LocalizedError, Sendable, Equatable {
    case disconnected, busy, background, posture, unverified, controlNotReady
    public var errorDescription: String? {
        switch self {
        case .disconnected: "机械臂未连接，请到设置 → 蓝牙设备连接 NexArm"
        case .busy: "机械臂正在处理上一项操作，请稍后重试"
        case .background: "请保持应用在前台后再控制机械臂"
        case .posture: "当前姿态不适合底座晃动，请先调整机械臂姿态后重试"
        case .unverified: "动作未确认完成，请检查机械臂后重新连接"
        case .controlNotReady: "蓝牙已连接，但控制尚未就绪，请到设置 → 蓝牙设备重新验证"
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
    private var motionID: UUID?
    private var generation = UUID()
    private var foreground = true
    private var observing = false
    private var pageVisible = false
    private var scanWanted = false
    private var discovery: Task<Void, Never>?
    private var forgetRequested = false
    private var reconnectEnabled = false
    private var manualDisconnectPending = false
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
        state.scanning = value.scanning
        state.nearby = value.devices.map { .init(id: $0.id, name: $0.name) }
        if let selected = value.selected, state.selected?.id == selected.id {
            state.selected = .init(id: selected.id, name: selected.name)
        }
        if value.phase == .disconnected && controller != nil {
            controller = nil
            motion?.cancel()
            state.phase = .idle
            state.controlValidated = false
            state.error = value.failure ?? "机械臂连接已断开，请重新连接"
        }
        if value.phase == .disconnecting && controller != nil {
            controller = nil
            motion?.cancel()
            state.phase = .disconnecting
            state.error = value.failure
        }
        if value.phase == .disconnected && state.phase == .disconnecting && cleanup == nil && operation == nil {
            state.phase = .idle
        }
        if value.discoveryLimitReached { state.notice = "附近设备较多，请靠近机械臂后重新搜索" }
        if let failure = value.failure, operation == nil, cleanup == nil { state.error = failure }
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
        else {
            state.error = "设备已不在列表中，请重新搜索"
            return
        }
        stopScan()
        generation = UUID()
        let token = generation
        if !automatically { reconnectEnabled = false }
        state.selected = device
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
                    if error as? NexArmError == .uncertainMotion {
                        reconnectEnabled = false
                        do { try await remember(state.remembered) } catch { state.error = error.localizedDescription }
                    }
                }
                await link.disconnect()
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
        try Task.checkCancellation()
        guard foreground, token == generation else { throw CancellationError() }
        try await remember(device)
        let ready = await link.status()
        try Task.checkCancellation()
        guard ready.phase == .connected, ready.selected?.id == device.id, token == generation, foreground else {
            throw NexArmError.disconnected
        }
        if indicate {
            state.phase = .indicating
            state.executing = true
            state.motionStatus = "正在复位并轻摇 ID5，提示连接成功…"
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
                state.motionStatus = "连接提示动作未完成"
                throw error
            }
            try Task.checkCancellation()
            let current = await link.status()
            guard foreground, token == generation, current.phase == .connected, current.selected?.id == device.id else {
                throw NexArmError.disconnected
            }
            state.motionStatus = "连接提示已完成"
        }
        reconnectEnabled = true
        try await remember(device)
        try Task.checkCancellation()
        let finalState = await link.status()
        guard foreground, token == generation, finalState.phase == .connected, finalState.selected?.id == device.id
        else {
            throw NexArmError.disconnected
        }
        controller = candidate
        state.phase = .connected
        state.controlValidated = true
        state.notice = indicate ? "已连接，可以返回对话控制机械臂" : "已自动恢复连接，可以继续控制机械臂"
    }
    public func disconnect() { disconnect(preserveReconnect: false) }
    private func disconnect(preserveReconnect: Bool) {
        recovery?.cancel()
        if !preserveReconnect {
            reconnectEnabled = false
            manualDisconnectPending = true
        }
        stopScan()
        guard cleanup == nil else { return }
        generation = UUID()  // Immediately fence in-flight connection verification.
        controller = nil
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
            if let movement {
                do { try await movement.value } catch {
                    if !(error is CancellationError) { state.error = Self.message(error) }
                }
            }
            await link.disconnect()
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
                    try await remember(nil)
                    state.selected = nil
                    state.notice = "已忽略设备"
                } catch { state.error = "移除设备记录失败：\(error.localizedDescription)" }
            }
        }
    }
    public func forget() {
        forgetRequested = true
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
    /// At most one attempt per foreground activation. No action queue or automatic gesture replay.
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
    }
    public func openSystemSettings() {
        #if os(iOS)
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        #endif
    }
    /// Invoked only by the composition-bound Action handler, never by a settings-page motor control.
    public func shakeBase(cycles: Int) async throws {
        try Task.checkCancellation()
        guard foreground else { throw BluetoothWorkflowError.background }
        guard (1...3).contains(cycles) else { throw NexArmError.invalidMotion }
        guard operation == nil, cleanup == nil, motion == nil else { throw BluetoothWorkflowError.busy }
        guard state.phase == .connected, let controller else { throw BluetoothWorkflowError.disconnected }
        guard state.controlReady else { throw BluetoothWorkflowError.controlNotReady }
        let token = UUID()
        let connectedGeneration = generation
        motionID = token
        state.executing = true
        state.motionStatus = "正在左右晃动 \(cycles) 次…"
        let task = Task { try await controller.shakeBase(cycles: cycles) }
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
            guard connectedGeneration == generation else { throw CancellationError() }
            state.motionStatus = "已完成 \(cycles) 次左右晃动并回位"
        } catch {
            state.motionStatus = error is CancellationError ? "动作已取消，未继续后续步骤" : "动作未完成"
            state.error = Self.message(error)
            if error as? NexArmError == .uncertainMotion {
                self.controller = nil
                state.controlValidated = false
                reconnectEnabled = false
                do { try await remember(state.remembered) } catch { state.error = error.localizedDescription }
                state.phase = .failed
            }
            if error as? NexArmError == .invalidMotion { throw BluetoothWorkflowError.posture }
            if error as? NexArmError == .uncertainMotion { throw BluetoothWorkflowError.unverified }
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
