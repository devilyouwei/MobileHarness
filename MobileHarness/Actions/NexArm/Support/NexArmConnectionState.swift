import Foundation
import Observation

public struct NexArmDeviceReference: Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
public enum NexArmManualAction: String, Sendable {
    case shakeBase, nod, shakeHead, wave, tiltLeft, tiltRight, lookAround, celebrate, dance, reset
}
public enum NexArmAvailability: String, Sendable { case unknown, available, poweredOff, denied, unsupported }
public enum NexArmConnectionPhase: String, Sendable { case idle, connecting, connected, disconnecting, failed }
public enum NexArmRecoveryStage: String, Sendable {
    case idle, cleaning, waiting, connecting, waitingForBluetooth, suspended, failed
    public var busy: Bool {
        switch self {
        case .cleaning, .waiting, .connecting: true
        default: false
        }
    }
}
@MainActor @Observable public final class NexArmConnectionState {
    public var availability: NexArmAvailability = .unknown
    public var phase: NexArmConnectionPhase = .idle
    public var scanning = false
    public var remembered: NexArmDeviceReference?
    public var nearby: [NexArmDeviceReference] = []
    public var selected: NexArmDeviceReference?
    public var recoveryStage: NexArmRecoveryStage = .idle
    public var recoveryDeviceID: String?
    public var recoveryAttempt = 0
    public var transportIssue: String?
    public var error: String?
    public var notice: String?
    public var jogging = false
    public var joints: [Int] = []
    public var pose: [Int] = []
    public var sampledAt: Date?
    public var canControl: Bool { phase == .connected && !recoveryStage.busy }
    public var controlReady: Bool { canControl }
    public init() {}
}
