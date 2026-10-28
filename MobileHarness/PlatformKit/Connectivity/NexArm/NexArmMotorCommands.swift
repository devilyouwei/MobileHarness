import Foundation

/// Host-side device envelope and transport budget. These values do not configure firmware protection.
public enum NexArmDeviceLimits {
    public static let motorIDs = 1...6
    public static let encoderCounts = 0...4095
    public static let countsPerRevolution = 4096
    public static let relativeDegrees = -360.0...360.0
    public static let positions = [210...3826, 200...3800, 968...3200, 728...3218, 908...3128, 1118...2828]
    public static let speed = 1...1400
    public static let acceleration = 1...254
    public static let defaultSpeed = speed.upperBound
    public static let defaultAcceleration = 30
    /// Conservative envelope for repeated finite position targets; never a continuous-speed servo mode.
    public static let livePositionMaximumSpeed = 600
    public static let livePositionMaximumAcceleration = 1800.0
    public static let livePositionMaximumJerk = 12000.0
    /// Recommended producer/worker cadence leaves room below the connection-wide BLE budget.
    public static let positionUpdateIntervalSeconds = 0.05
    public static let positionUpdateInterval: Duration = .seconds(positionUpdateIntervalSeconds)
    /// Shared by finite requests, live control and observation; burst capacity is one.
    public static let minimumBLEWriteIntervalSeconds = 0.03
    public static let minimumBLEWriteInterval: Duration = .seconds(minimumBLEWriteIntervalSeconds)
}

/// Hardware motion options use native encoder/register units, not guessed physical units.
public struct NexArmMotorOptions: Sendable, Equatable {
    public let speed: Int
    public let acceleration: Int
    public init(
        speed: Int = NexArmDeviceLimits.defaultSpeed, acceleration: Int = NexArmDeviceLimits.defaultAcceleration
    ) throws {
        guard NexArmDeviceLimits.speed.contains(speed), NexArmDeviceLimits.acceleration.contains(acceleration) else {
            throw NexArmError.invalidMotion
        }
        self.speed = speed
        self.acceleration = acceleration
    }
}
/// Encodes native position registers; no reset/home or gesture semantics.
public enum NexArmMotorCommands {
    public static let positionLimits = NexArmDeviceLimits.positions
    /// Signed encoder-space degrees from a measured position; never clamps or wraps a target.
    public static func relativeTarget(motor: Int, from: Int, deltaDegrees: Double) throws -> Int {
        guard NexArmDeviceLimits.motorIDs.contains(motor), NexArmDeviceLimits.encoderCounts.contains(from),
            deltaDegrees.isFinite, NexArmDeviceLimits.relativeDegrees.contains(deltaDegrees)
        else { throw NexArmError.invalidMotion }
        let offset = Int((deltaDegrees * Double(NexArmDeviceLimits.countsPerRevolution) / 360).rounded())
        let target = from + offset
        guard positionLimits[motor - 1].contains(target) else { throw NexArmError.invalidMotion }
        return target
    }
    public static func move(motor: Int, target: Int, options: NexArmMotorOptions) throws -> NexArmPacket {
        guard NexArmDeviceLimits.motorIDs.contains(motor), positionLimits[motor - 1].contains(target) else {
            throw NexArmError.invalidMotion
        }
        return try NexArmPacket(
            id: UInt8(motor), command: 3,
            payload: [
                41, UInt8(options.acceleration), UInt8(target & 255), UInt8(target >> 8), 0, 0,
                UInt8(options.speed & 255), UInt8(options.speed >> 8),
            ])
    }
    /// One native synchronous register write to distinct addressed motors.
    public static func simultaneous(_ atoms: [NexArmPacket]) throws -> NexArmPacket {
        guard NexArmDeviceLimits.motorIDs.contains(atoms.count), Set(atoms.map(\.id)).count == atoms.count,
            atoms.allSatisfy({ $0.command == 3 && $0.motorTargets?.count == 1 })
        else {
            throw NexArmError.invalidMotion
        }
        if atoms.count == 1 { return atoms[0] }
        return try NexArmPacket(
            id: 254, command: 131,
            payload: [41, 7] + atoms.flatMap { [$0.id] + $0.payload.dropFirst() })
    }
}

/// Device tolerance and empirical travel estimates in native units; no action or home semantics.
public enum NexArmMotorProfiles {
    public struct Profile: Sendable {
        public let tolerance: Int
    }
    public struct Budget: Sendable {
        public let expectedMilliseconds: Int
        public let timeoutMilliseconds: Int
        public let offTargetMilliseconds: Int
    }
    // See README measurement record. These are arrival regions, not accuracy guarantees.
    public static func profile(for motor: Int) -> Profile {
        switch motor {
        case 1: Profile(tolerance: 16)
        case 2: Profile(tolerance: 20)
        case 3: Profile(tolerance: 56)
        case 4: Profile(tolerance: 32)
        case 5: Profile(tolerance: 16)
        default: Profile(tolerance: 24)
        }
    }
    public static func budget(motor: Int, from: Int?, target: Int, options: NexArmMotorOptions) -> Budget {
        let limits = NexArmMotorCommands.positionLimits[min(6, max(1, motor)) - 1]
        let distance =
            from.map { abs(target - $0) } ?? max(abs(target - limits.lowerBound), abs(target - limits.upperBound))
        // Conservative empirical envelope, not an undocumented physical acceleration conversion.
        // 80-count trials at speed400/800/1400, acceleration30/50 took roughly 0.25–0.50s.
        let ramp = 0.4 * sqrt(30.0 / Double(options.acceleration))
        let expected = Double(distance) / Double(options.speed) + ramp + 0.2
        let stationary = max(0.6, 8.0 / Double(options.speed) + ramp)
        return Budget(
            expectedMilliseconds: Int(ceil(expected * 1000)),
            timeoutMilliseconds: Int(ceil((3 * expected + 1.2) * 1000)),
            offTargetMilliseconds: Int(ceil(stationary * 1000)))
    }
}

public struct NexArmFeedbackConfiguration: Sendable, Equatable {
    public let tolerance: Int?
    public let stableTolerance: Int
    public let offTargetMilliseconds: Int
    public let feedbackMilliseconds: Int
    public let timeoutMilliseconds: Int?
    public init(
        tolerance: Int? = nil, stableTolerance: Int = 2,
        offTargetMilliseconds: Int = 600, feedbackMilliseconds: Int = 2000,
        timeoutMilliseconds: Int? = nil
    ) throws {
        guard tolerance.map({ (0...64).contains($0) }) ?? true, (0...8).contains(stableTolerance),
            (100...60_000).contains(offTargetMilliseconds),
            (200...5000).contains(feedbackMilliseconds),
            timeoutMilliseconds.map({ (200...86_400_000).contains($0) }) ?? true
        else { throw NexArmError.invalidMotion }
        self.tolerance = tolerance
        self.stableTolerance = stableTolerance
        self.offTargetMilliseconds = offTargetMilliseconds
        self.feedbackMilliseconds = feedbackMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}
/// Fresh encoder feedback determines progress; there is no nominal-duration gate.
public struct NexArmPositionObservation: Sendable {
    public enum Outcome: Equatable, Sendable { case waiting, arrived, unreached, timedOut }
    private let targets: [Int: Int]
    private let policy: NexArmFeedbackConfiguration?
    private let started: ContinuousClock.Instant
    private let deadline: ContinuousClock.Instant
    private var lastSample: ContinuousClock.Instant?
    private var anchor: [Int: Int] = [:]
    private var stableSince: ContinuousClock.Instant?
    private var sampleCount = 0
    private var atTarget = false
    public init(
        targets: [Int: Int], started: ContinuousClock.Instant, deadline: ContinuousClock.Instant,
        policy: NexArmFeedbackConfiguration? = nil
    ) {
        self.policy = policy
        self.targets = targets
        self.started = started
        self.deadline = deadline
    }
    public mutating func observe(joints: [Int], at time: ContinuousClock.Instant) {
        guard joints.count == 6, !targets.isEmpty, targets.keys.allSatisfy({ (1...6).contains($0) }),
            time >= started, lastSample.map({ time > $0 }) ?? true
        else { return }
        lastSample = time
        atTarget = targets.allSatisfy { id, target in
            abs(joints[id - 1] - target) <= (policy?.tolerance ?? NexArmMotorProfiles.profile(for: id).tolerance)
        }
        let stable =
            !anchor.isEmpty
            && anchor.allSatisfy { id, value in abs(joints[id - 1] - value) <= (policy?.stableTolerance ?? 2) }
        if stable {
            sampleCount += 1
        } else {
            anchor = Dictionary(uniqueKeysWithValues: targets.keys.map { ($0, joints[$0 - 1]) })
            stableSince = time
            sampleCount = 1
        }
    }
    public func outcome(at now: ContinuousClock.Instant) -> Outcome {
        // Arrival takes priority over stability and the polling deadline.
        if let lastSample, lastSample <= deadline, atTarget { return .arrived }
        // Silence is not stability: only fresh samples extend this interval.
        if let policy, let stableSince, let lastSample, lastSample <= deadline,
            !atTarget, sampleCount >= 2,
            lastSample - stableSince >= .milliseconds(policy.offTargetMilliseconds)
        {
            return .unreached
        }
        return now >= deadline ? .timedOut : .waiting
    }
}
