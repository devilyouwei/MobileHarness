import Foundation
import Observation

public enum BluetoothAvailability: Sendable { case unknown, available, poweredOff, denied, unsupported }
public enum BluetoothConnectionPhase: Sendable {
    case idle, connecting, verifying, indicating, connected, disconnecting, failed
}
public struct BluetoothDeviceRow: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}
@MainActor
public protocol BluetoothControlling: AnyObject {
    func reconnect(_ id: UUID)
    func clearIncidents(_ id: UUID)
    func refreshDevice() async
    func tryAction(_ action: BluetoothArmAction)
    func setMotorVelocity(id: Int, value: Double)
    func stopMotorControl()
    func openPage()
    func closePage()
    func scan()
    func stopScan()
    func connect(_ id: UUID)
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
    case idle, cleaning, waiting, connecting, verifying, waitingForBluetooth, suspended, failed
    public var title: String {
        switch self {
        case .idle: "无恢复任务"
        case .cleaning: "正在清理旧连接"
        case .waiting: "等待重新连接"
        case .connecting: "正在重新连接"
        case .verifying: "正在验证控制"
        case .waitingForBluetooth: "等待蓝牙恢复"
        case .suspended: "恢复已暂停，返回前台后继续"
        case .failed: "恢复未完成，需要处理"
        }
    }
    public var busy: Bool {
        switch self {
        case .cleaning, .waiting, .connecting, .verifying: true
        default: false
        }
    }
}

/// Bounded display-only diagnostic values; no device SDK types enter UI.
public struct BluetoothIncident: Identifiable, Sendable {
    public let id: UUID
    public let episodeID: UUID
    public let deviceID: UUID
    public let time: Date
    public let cause: String
    public let stage: String
    public let message: String
    public let attempt: Int
    public let elapsedSeconds: Double
    public let details: [String]
    public init(
        id: UUID = UUID(), episodeID: UUID, deviceID: UUID, time: Date = Date(), cause: String,
        stage: String, message: String, attempt: Int, elapsedSeconds: Double, details: [String]
    ) {
        self.id = id
        self.episodeID = episodeID
        self.deviceID = deviceID
        self.time = time
        self.cause = String(cause.prefix(128))
        self.stage = String(stage.prefix(128))
        self.message = String(message.prefix(512))
        self.attempt = attempt
        self.elapsedSeconds = elapsedSeconds
        self.details = details.prefix(10).map { String($0.prefix(256)) }
    }
}

/// Presentation values only; AppWorkflows owns discovery, connections, persistence and motion.
@MainActor @Observable
public final class BluetoothSettingsState {
    public var availability: BluetoothAvailability = .unknown
    public var phase: BluetoothConnectionPhase = .idle
    public var transportStatus = "未连接"
    public var scanning = false
    public var remembered: BluetoothDeviceRow?
    public var nearby: [BluetoothDeviceRow] = []
    public var selected: BluetoothDeviceRow?
    public var recoveryStage: BluetoothRecoveryStage = .idle
    public var recoveryDeviceID: UUID?
    public var recoveryAttempt = 0
    public var incidents: [BluetoothIncident] = []
    public func incidents(for id: UUID) -> [BluetoothIncident] { incidents.filter { $0.deviceID == id } }
    public var controlValidated = false
    public var error: String?
    public var notice: String?
    public var motionStatus: String?
    public var executing = false
    public var refreshing = false
    public var jogging = false
    public var testing = false
    public var resetting = false
    public var joints: [Int] = []
    public var pose: [Int] = []
    public var sampledAt: Date?
    /// Manual controls remain available for takeover while a previous operation is active.
    public var canControl: Bool { controlReady }

    public init() {}
    public var controlReady: Bool { phase == .connected && controlValidated && !recoveryStage.busy }
    public var connectionBusy: Bool {
        recoveryStage.busy || phase == .connecting || phase == .verifying || phase == .indicating
            || phase == .disconnecting
    }
    public var canScan: Bool {
        !connectionBusy && phase != .connected && (availability == .available || availability == .unknown)
    }
    public var summary: String {
        switch phase {
        case .connected: controlReady ? (selected?.name ?? "已连接") : "已连接，控制待验证"
        case .connecting: "正在连接…"
        case .verifying: "正在检查设备…"
        case .indicating: "正在执行连接提示…"
        case .disconnecting: "正在断开…"
        case .failed: "连接不可用"
        case .idle: availability == .poweredOff ? "蓝牙已关闭" : "未连接"
        }
    }
    public func status(for id: UUID) -> String {
        guard selected?.id == id else { return "未连接" }
        switch phase {
        case .connected: return controlReady ? (executing ? "动作执行中" : "已连接") : "已连接，控制未就绪"
        case .connecting: return "正在连接…"
        case .verifying: return "正在检查…"
        case .indicating: return "正在复位 / 提示…"
        case .disconnecting: return "正在断开…"
        case .failed: return "需要重新连接"
        case .idle: return "未连接"
        }
    }
}
