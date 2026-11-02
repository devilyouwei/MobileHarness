import Foundation
import Observation

public enum BluetoothAvailability: String, CaseIterable, Sendable {
    case unknown, available, poweredOff, denied, unsupported
}
public enum BluetoothConnectionPhase: String, CaseIterable, Sendable {
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
public enum BluetoothConnectionStatus: String, Equatable, Sendable {
    case disconnected, connecting, connected
    public var isConnecting: Bool { self == .connecting }
    public var title: String {
        switch self {
        case .disconnected: "未连接"
        case .connecting: "正在连接…"
        case .connected: "已连接"
        }
    }
}
@MainActor public protocol BluetoothConnectionPresenting: AnyObject, Sendable {
    @discardableResult func presentBluetoothConnection(_ value: BluetoothConnectionStatus, revision: UInt64) -> Bool
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

public enum BluetoothRecoveryStage: String, CaseIterable, Sendable {
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
@MainActor
@Observable
public final class BluetoothSettingsState {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    @ObservationIgnored var pendingPresentation: BluetoothViewSnapshot?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public internal(set) var availability: BluetoothAvailability = .unknown
    public internal(set) var phase: BluetoothConnectionPhase = .idle
    public internal(set) var scanning = false
    public internal(set) var remembered: BluetoothDeviceRow?
    public internal(set) var nearby: [BluetoothDeviceRow] = []
    public internal(set) var selected: BluetoothDeviceRow?
    public internal(set) var recoveryStage: BluetoothRecoveryStage = .idle
    public internal(set) var recoveryDeviceID: String?
    public internal(set) var recoveryAttempt = 0
    /// Latest native communication issue, adapted by Actions.
    public internal(set) var transportIssue: String?
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
    public internal(set) var error: String?
    public internal(set) var notice: String?
    public internal(set) var jogging = false
    public internal(set) var joints: [Int] = []
    public internal(set) var pose: [Int] = []
    public internal(set) var sampledAt: Date?
    /// Manual controls remain available for takeover while a previous operation is active.
    public var canControl: Bool { phase == .connected && !recoveryStage.busy }

    public internal(set) var connectionPresentation: BluetoothConnectionStatus = .disconnected
    private var connectionRevision: UInt64 = 0
    @discardableResult public func presentBluetoothConnection(_ value: BluetoothConnectionStatus, revision: UInt64)
        -> Bool
    {
        guard presentationAdmission?.acceptsRetained() ?? true, revision > 0, revision >= connectionRevision else {
            return false
        }
        guard revision != connectionRevision || value == connectionPresentation else { return false }
        connectionRevision = revision
        connectionPresentation = value
        return true
    }
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

    @discardableResult
    public func present(_ update: DeviceSettingsUpdate) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        apply(update)
        return true
    }
    func apply(_ update: DeviceSettingsUpdate) {
        switch update {
        case .availability(let value): availability = value
        case .phase(let value): phase = value
        case .scanning(let value): scanning = value
        case .remembered(let value): remembered = value
        case .nearby(let value): nearby = value
        case .selected(let value): selected = value
        case .recoveryStage(let value): recoveryStage = value
        case .recoveryDeviceID(let value): recoveryDeviceID = value
        case .recoveryAttempt(let value): recoveryAttempt = value
        case .transportIssue(let value): transportIssue = value
        case .error(let value): error = value
        case .notice(let value): notice = value
        case .jogging(let value): jogging = value
        case .joints(let value): joints = value
        case .pose(let value): pose = value
        case .sampledAt(let value): sampledAt = value
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
        if let admission = presentationAdmission, !admission.started, !admission.stopped {
            pendingPresentation = snapshot
            return
        }
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
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

public enum DeviceSettingsUpdate {
    case availability(BluetoothAvailability)
    case phase(BluetoothConnectionPhase)
    case scanning(Bool)
    case remembered(BluetoothDeviceRow?)
    case nearby([BluetoothDeviceRow])
    case selected(BluetoothDeviceRow?)
    case recoveryStage(BluetoothRecoveryStage)
    case recoveryDeviceID(String?)
    case recoveryAttempt(Int)
    case transportIssue(String?)
    case error(String?)
    case notice(String?)
    case jogging(Bool)
    case joints([Int])
    case pose([Int])
    case sampledAt(Date?)
}

@MainActor
public protocol DeviceSettingsPresenting: UIPresentationAccess, BluetoothConnectionPresenting {
    var availability: BluetoothAvailability { get }
    var phase: BluetoothConnectionPhase { get }
    var scanning: Bool { get }
    var remembered: BluetoothDeviceRow? { get }
    var nearby: [BluetoothDeviceRow] { get }
    var selected: BluetoothDeviceRow? { get }
    var recoveryStage: BluetoothRecoveryStage { get }
    var recoveryDeviceID: String? { get }
    var recoveryAttempt: Int { get }
    var transportIssue: String? { get }
    var error: String? { get }
    var notice: String? { get }
    var jogging: Bool { get }
    var joints: [Int] { get }
    var pose: [Int] { get }
    var sampledAt: Date? { get }
    var canControl: Bool { get }
    var canConnect: Bool { get }
    var canScan: Bool { get }
    var summary: String { get }
    var controlReady: Bool { get }
    var connectionBusy: Bool { get }
    @discardableResult
    func present(_ update: DeviceSettingsUpdate) -> Bool
    func apply(_ snapshot: BluetoothViewSnapshot)
    func rowIntent(for id: String) -> BluetoothDeviceRowIntent
    func isConnected(_ id: String) -> Bool
    func hasConnectionIssue(_ id: String) -> Bool
    func canControl(_ id: String) -> Bool
    func currentMessage(for id: String) -> String?
    func status(for id: String) -> String
}

extension BluetoothSettingsState: DeviceSettingsPresenting {}

@MainActor
public final class UIDeviceSettingsContainer {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        return UIStateSnapshot(
            path: "ui.devices",
            business: [
                "phase": .text(state.phase.rawValue), "scanning": .flag(state.scanning),
            ],
            runtime: [
                "available": .flag(state.isPresentationAvailable),
                "recovery": .text(state.recoveryStage.rawValue),
            ], meanings: ["business.phase": "Displayed device connection phase; not a physical motion phase"],
            stateValues: [
                "business.phase": BluetoothConnectionPhase.allCases.map(\.rawValue),
                "runtime.recovery": BluetoothRecoveryStage.allCases.map(\.rawValue),
            ])
    }

    public let requests = UIRequests<DeviceInput, Void>()

    public let state = BluetoothSettingsState()
    public var presentation: any DeviceSettingsPresenting { state }
    func startPresentation() {
        if let pending = state.pendingPresentation {
            state.pendingPresentation = nil
            state.apply(pending)
        }
    }
    func stopPresentation() { state.pendingPresentation = nil }
    init(admission: UIPresentationAdmission) { state.presentationAdmission = admission }
}

public struct DeviceInput: Sendable {
    public let parameters: [String: String]
    public init(_ parameters: [String: String]) { self.parameters = parameters }
}
