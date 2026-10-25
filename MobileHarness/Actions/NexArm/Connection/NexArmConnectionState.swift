import Foundation
import FunctionContracts
import Observation

@MainActor @Observable public final class NexArmConnectionState {
    @ObservationIgnored public var onFactsChanged: (@MainActor () -> Void)?
    public var availability: NexArmAvailability = .unknown { didSet { onFactsChanged?() } }
    public var phase: NexArmConnectionPhase = .idle { didSet { onFactsChanged?() } }
    public var scanning = false
    public var remembered: NexArmDeviceReference?
    public var nearby: [NexArmDeviceReference] = []
    public var selected: NexArmDeviceReference?
    public var recoveryStage: NexArmRecoveryStage = .idle { didSet { onFactsChanged?() } }
    public var recoveryDeviceID: String?
    public var recoveryAttempt = 0
    public var transportIssue: String?
    public var error: String?
    public var notice: String?
    public var jogging = false { didSet { onFactsChanged?() } }
    public var joints: [Int] = []
    public var pose: [Int] = []
    public var sampledAt: Date?
    public var canControl: Bool { phase == .connected && !recoveryStage.busy }
    public var controlReady: Bool { canControl }
    public init() {}
}
