import Foundation
import Observation

public enum BluetoothAvailability: Sendable { case unknown, available, poweredOff, denied, unsupported }
public enum BluetoothConnectionPhase: Sendable {
    case idle, connecting, connected, disconnecting, failed
}
public enum BluetoothDeviceRowIntent: Sendable { case connect, openDetail, unavailable }
public struct BluetoothDeviceRow: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
@MainActor
public protocol BluetoothControlling: AnyObject {
    func reconnect(_ id: String)
    func refreshDevice() async
    func tryAction(_ action: BluetoothArmAction)
    func setMotorVelocity(id: Int, value: Double)
    func stopMotorControl()
    func openPage()
    func closePage()
    func scan()
    func stopScan()
    func connect(_ id: String)
    func disconnect()
    func forget()
    func openSystemSettings()
}

public enum BluetoothArmAction: String, CaseIterable, Identifiable, Sendable {
    case shakeBase, nod, shakeHead, wave, tiltLeft, tiltRight, lookAround, celebrate, dance, reset
    public var id: Self { self }
    public var title: String {
        switch self {
        case .shakeBase: "底座晃动"
        case .nod: "点头"
        case .shakeHead: "摇头"
        case .wave: "挥手"
        case .tiltLeft: "向左歪头"
        case .tiltRight: "向右歪头"
        case .lookAround: "左右张望"
        case .celebrate: "庆祝"
        case .dance: "小舞蹈"
        case .reset: "整臂归位"
        }
    }
}

public enum BluetoothRecoveryStage: Sendable {
    case idle, cleaning, waiting, connecting, waitingForBluetooth, suspended, failed
    public var title: String {
        switch self {
        case .idle: "无恢复任务"
        case .cleaning: "正在清理旧连接"
        case .waiting: "等待重新连接"
        case .connecting: "正在重新连接"
        case .waitingForBluetooth: "等待蓝牙恢复"
        case .suspended: "恢复已暂停，返回前台后继续"
        case .failed: "恢复未完成，需要处理"
        }
    }
    public var busy: Bool {
        switch self {
        case .cleaning, .waiting, .connecting: true
        default: false
        }
    }
}

/// Presentation values only; NexArmControlService owns discovery, connections, persistence and motion.
@MainActor @Observable
public final class BluetoothSettingsState {
    public var availability: BluetoothAvailability = .unknown
    public var phase: BluetoothConnectionPhase = .idle
    public var scanning = false
    public var remembered: BluetoothDeviceRow?
    public var nearby: [BluetoothDeviceRow] = []
    public var selected: BluetoothDeviceRow?
    public var recoveryStage: BluetoothRecoveryStage = .idle
    public var recoveryDeviceID: String?
    public var recoveryAttempt = 0
    /// Latest native communication issue, adapted by ActionBindings.
    public var transportIssue: String?
    /// Connected or remembered devices belong to My Devices; a new pending selection stays nearby.
    public var myDevice: BluetoothDeviceRow? {
        if phase == .connected, let selected { return selected }
        if let remembered { return selected?.id == remembered.id ? selected : remembered }
        return nil
    }
    public var otherDevices: [BluetoothDeviceRow] {
        var rows = nearby.filter { $0.id != myDevice?.id }
        if let selected, selected.id != myDevice?.id, !rows.contains(where: { $0.id == selected.id }) {
            rows.insert(selected, at: 0)
        }
        return rows
    }
    public func rowIntent(for id: String) -> BluetoothDeviceRowIntent {
        if isConnected(id) { return .openDetail }
        return canConnect ? .connect : .unavailable
    }
    public func isConnected(_ id: String) -> Bool { selected?.id == id && phase == .connected }
    public func hasConnectionIssue(_ id: String) -> Bool { isConnected(id) && transportIssue != nil }
    public func canControl(_ id: String) -> Bool { isConnected(id) && canControl }
    public func currentMessage(for id: String) -> String? {
        let currentID = selected?.id ?? (recoveryStage == .idle ? nil : recoveryDeviceID) ?? remembered?.id
        guard currentID == id else { return nil }
        if isConnected(id) { return transportIssue }
        if recoveryStage != .idle { return error ?? notice }
        return phase == .failed ? error : nil
    }
    public var error: String?
    public var notice: String?
    public var jogging = false
    public var joints: [Int] = []
    public var pose: [Int] = []
    public var sampledAt: Date?
    /// Manual controls remain available for takeover while a previous operation is active.
    public var canControl: Bool { phase == .connected && !recoveryStage.busy }

    public init() {}
    public var controlReady: Bool { phase == .connected && !recoveryStage.busy }
    public var connectionBusy: Bool {
        recoveryStage.busy || phase == .connecting || phase == .disconnecting
    }
    public var canConnect: Bool {
        !connectionBusy && phase != .connected && (availability == .available || availability == .unknown)
    }
    public var canScan: Bool {
        canConnect
    }
    /// Latest connection/communication status never consumes Action/Tool execution outcomes.
    public var summary: String { connectionTitle }
    public func status(for id: String) -> String {
        (selected?.id ?? (recoveryStage == .idle ? nil : recoveryDeviceID)) == id ? connectionTitle : "未连接"
    }
    private var connectionTitle: String {
        switch phase {
        case .connected: transportIssue == nil ? "已连接" : "已连接，异常"
        case .connecting: recoveryStage == .connecting ? "正在重连…" : "正在连接…"
        case .disconnecting: "正在断开…"
        case .failed: "未连接"
        case .idle:
            switch recoveryStage {
            case .cleaning, .waiting, .connecting: "正在重连…"
            case .waitingForBluetooth: "等待蓝牙开启"
            case .failed: "未连接"
            case .idle, .suspended: "未连接"
            }
        }
    }
}

public struct BluetoothViewSnapshot: Sendable {
    public var availability: BluetoothAvailability = .unknown
    public var phase: BluetoothConnectionPhase = .idle
    public var scanning = false
    public var remembered: BluetoothDeviceRow?
    public var nearby: [BluetoothDeviceRow] = []
    public var selected: BluetoothDeviceRow?
    public var recoveryStage: BluetoothRecoveryStage = .idle
    public var recoveryDeviceID: String?
    public var recoveryAttempt = 0
    public var transportIssue: String?
    public var error: String?
    public var notice: String?
    public var jogging = false
    public var joints: [Int] = []
    public var pose: [Int] = []
    public var sampledAt: Date?
    public init() {}
}

extension BluetoothSettingsState {
    public func apply(_ snapshot: BluetoothViewSnapshot) {
        availability = snapshot.availability
        phase = snapshot.phase
        scanning = snapshot.scanning
        remembered = snapshot.remembered
        nearby = snapshot.nearby
        selected = snapshot.selected
        recoveryStage = snapshot.recoveryStage
        recoveryDeviceID = snapshot.recoveryDeviceID
        recoveryAttempt = snapshot.recoveryAttempt
        transportIssue = snapshot.transportIssue
        error = snapshot.error
        notice = snapshot.notice
        jogging = snapshot.jogging
        joints = snapshot.joints
        pose = snapshot.pose
        sampledAt = snapshot.sampledAt
    }
}
