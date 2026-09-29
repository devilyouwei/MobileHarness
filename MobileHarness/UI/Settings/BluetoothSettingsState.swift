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
    func openPage()
    func closePage()
    func scan()
    func stopScan()
    func connect(_ id: UUID)
    func disconnect()
    func forget()
    func openSystemSettings()
}

/// Presentation values only; AppWorkflows owns discovery, connections, persistence and motion.
@MainActor @Observable
public final class BluetoothSettingsState {
    public var availability: BluetoothAvailability = .unknown
    public var phase: BluetoothConnectionPhase = .idle
    public var scanning = false
    public var remembered: BluetoothDeviceRow?
    public var nearby: [BluetoothDeviceRow] = []
    public var selected: BluetoothDeviceRow?
    public var controlValidated = false
    public var error: String?
    public var notice: String?
    public var motionStatus: String?
    public var executing = false
    public init() {}
    public var controlReady: Bool { phase == .connected && controlValidated }
    public var connectionBusy: Bool {
        phase == .connecting || phase == .verifying || phase == .indicating || phase == .disconnecting
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
        case .connected: return controlReady ? (executing ? "动作执行中" : "已连接") : "控制待验证"
        case .connecting: return "正在连接…"
        case .verifying: return "正在检查…"
        case .indicating: return "正在复位 / 提示…"
        case .disconnecting: return "正在断开…"
        case .failed: return "需要重新连接"
        case .idle: return "未连接"
        }
    }
}
