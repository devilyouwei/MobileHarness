import Foundation

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
public struct NexArmConnectionFacts: Sendable, Equatable {
    public let availability: NexArmAvailability
    public let phase: NexArmConnectionPhase
    public let recovery: NexArmRecoveryStage
    public init(availability: NexArmAvailability, phase: NexArmConnectionPhase, recovery: NexArmRecoveryStage) {
        self.availability = availability
        self.phase = phase
        self.recovery = recovery
    }
}
