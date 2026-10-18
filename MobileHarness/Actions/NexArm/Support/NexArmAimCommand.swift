import Foundation
import PlatformKit

/// Tracking command for motors 1 and 4. Shoulder and elbow stay on one position-mode preparation.
/// After that preparation, motors 1 and 4 use closed-loop speed. A sent packet is not physical arrival.
/// An admitted speed is held until the target changes, or the target has stayed unchanged for 0.3 seconds.
public struct NexArmAimCommand: Sendable {
    public struct Command: Sendable, Equatable {
        public let packet: NexArmPacket
        public let levelsForearm: Bool
        fileprivate let step: Step
        fileprivate let time: ContinuousClock.Instant
    }

    fileprivate enum Step: Equatable, Sendable {
        case level
        case engage(Int)
        case speed(baseSpeed: Int, pitchSpeed: Int, base: Int, pitch: Int)
    }

    private static let scale = 2.2
    private static let maxMagnitude = 600
    private static let correctionHorizon = 0.35
    private static let correctionLimit = 80.0
    private static let deadman = 0.30

    private var seeded = false
    private var referenceBase = 0
    private var referencePitch = 0
    private var estimatedBase = 0.0
    private var estimatedPitch = 0.0
    private var integratedAt: ContinuousClock.Instant?
    private var forearmAdmitted = false
    private var engageIndex = 0
    private var speedAdmitted = false
    private var referenceTime: ContinuousClock.Instant?
    private var heldBaseSpeed = 0
    private var heldPitchSpeed = 0
    private var pending: Command?
    private var modeOpen = false

    public init() {}

    /// First estimate of where the two axes already are. Later calls keep that estimate.
    public mutating func seed(base: Int, pitch: Int) throws {
        guard !seeded else { return }
        guard Self.legal(base, motor: 1), Self.legal(pitch, motor: 4) else {
            throw NexArmExecutionError.invalidArguments
        }
        referenceBase = base
        referencePitch = pitch
        estimatedBase = Double(base)
        estimatedPitch = Double(pitch)
        seeded = true
    }

    public mutating func reset() {
        self = NexArmAimCommand()
    }

    /// The next packet. Nil means the admitted speed already matches this target, or speed mode is idle at zero.
    /// The same command is returned until `accept`; a newer target replaces an unadmitted speed.
    public mutating func command(base: Int, pitch: Int, at time: ContinuousClock.Instant) throws -> Command? {
        guard seeded, Self.legal(base, motor: 1), Self.legal(pitch, motor: 4) else {
            throw NexArmExecutionError.invalidArguments
        }
        if !forearmAdmitted {
            if let pending, pending.step == .level { return pending }
            let command = Command(packet: try Self.forearmLevel(), levelsForearm: true, step: .level, time: time)
            pending = command
            return command
        }
        if engageIndex < Self.engage.count {
            if let pending, pending.step == .engage(engageIndex) { return pending }
            let command = Command(
                packet: Self.engage[engageIndex], levelsForearm: false, step: .engage(engageIndex), time: time)
            pending = command
            return command
        }
        guard let speeds = desiredSpeeds(base: base, pitch: pitch, at: time) else { return nil }
        if speedAdmitted, speeds.base == heldBaseSpeed, speeds.pitch == heldPitchSpeed {
            if base != referenceBase || pitch != referencePitch {
                referenceBase = base
                referencePitch = pitch
                referenceTime = time
            }
            pending = nil
            return nil
        }
        if let pending, case .speed(let baseSpeed, let pitchSpeed, let pendingBase, let pendingPitch) = pending.step,
            baseSpeed == speeds.base, pitchSpeed == speeds.pitch, pendingBase == base, pendingPitch == pitch
        {
            return pending
        }
        pending = nil
        if speeds.base == 0, speeds.pitch == 0, !speedAdmitted { return nil }
        let command = Command(
            packet: try NexArmMotorCommands.trackingSpeeds(base: speeds.base, pitch: speeds.pitch),
            levelsForearm: false,
            step: .speed(baseSpeed: speeds.base, pitchSpeed: speeds.pitch, base: base, pitch: pitch),
            time: time)
        pending = command
        return command
    }

    public mutating func accept(_ command: Command) {
        guard pending == command else { return }
        switch command.step {
        case .level:
            forearmAdmitted = true
        case .engage(let index):
            guard index == engageIndex else { return }
            engageIndex += 1
            if engageIndex == Self.engage.count { modeOpen = true }
        case .speed(let baseSpeed, let pitchSpeed, let base, let pitch):
            integrate(to: command.time)
            heldBaseSpeed = baseSpeed
            heldPitchSpeed = pitchSpeed
            referenceBase = base
            referencePitch = pitch
            referenceTime = command.time
            speedAdmitted = true
        }
        pending = nil
    }

    /// Packets that return motors 1 and 4 to position mode. Empty when speed mode was never started.
    public mutating func releasePackets(base: Int, pitch: Int) -> [NexArmPacket] {
        guard modeOpen || engageIndex > 0 else { return [] }
        modeOpen = false
        engageIndex = Self.engage.count
        speedAdmitted = false
        heldBaseSpeed = 0
        heldPitchSpeed = 0
        let holdBase = Self.legal(base, motor: 1) ? base : referenceBase
        let holdPitch = Self.legal(pitch, motor: 4) ? pitch : referencePitch
        let hold: [NexArmPacket]
        if let packet = try? NexArmMotorCommands.simultaneous([
            try NexArmMotorCommands.move(
                motor: 1, target: holdBase, options: try NexArmMotorOptions(speed: 300, acceleration: 30)),
            try NexArmMotorCommands.move(
                motor: 4, target: holdPitch, options: try NexArmMotorOptions(speed: 300, acceleration: 30)),
        ]) {
            hold = [packet]
        } else {
            hold = []
        }
        return [Self.stopped] + Self.disengage + hold
    }

    /// Nil before any speed write when the target is still the seed. Otherwise the speed to hold or send.
    private mutating func desiredSpeeds(base: Int, pitch: Int, at time: ContinuousClock.Instant) -> (
        base: Int, pitch: Int
    )? {
        integrate(to: time)
        let changed = base != referenceBase || pitch != referencePitch
        if !changed {
            let idle = referenceTime.map { Self.seconds(time - $0) } ?? 0
            if speedAdmitted, idle >= Self.deadman, (heldBaseSpeed != 0 || heldPitchSpeed != 0) {
                return (0, 0)
            }
            if !speedAdmitted { return nil }
            return (heldBaseSpeed, heldPitchSpeed)
        }
        let elapsed = referenceTime.map { min(0.5, max(0.02, Self.seconds(time - $0))) } ?? 0.2
        return (
            Self.encode(
                rate: Self.rate(target: base, reference: referenceBase, estimate: estimatedBase, dt: elapsed)),
            Self.encode(
                rate: Self.rate(target: pitch, reference: referencePitch, estimate: estimatedPitch, dt: elapsed)))
    }

    private mutating func integrate(to time: ContinuousClock.Instant) {
        guard let from = integratedAt else {
            integratedAt = time
            return
        }
        let elapsed = Self.seconds(time - from)
        guard elapsed > 0 else { return }
        estimatedBase += Self.countsPerSecond(heldBaseSpeed) * elapsed
        estimatedPitch += Self.countsPerSecond(heldPitchSpeed) * elapsed
        integratedAt = time
    }

    /// Feedforward covers the new step. Correction covers only the miss against the previous target.
    private static func rate(target: Int, reference: Int, estimate: Double, dt: Double) -> Double {
        let feedforward = Double(target - reference) / dt
        let lag = Double(reference) - estimate
        let correction = min(correctionLimit, max(-correctionLimit, lag / correctionHorizon))
        let maxRate = Double(maxMagnitude) / scale
        return min(maxRate, max(-maxRate, feedforward + correction))
    }

    /// Bit 15 clear decreases the encoder on motors 1 and 4. On motor 1 that turns the arm left.
    /// A positive rate increases the count and sets bit 15.
    private static func encode(rate: Double) -> Int {
        let magnitude = min(maxMagnitude, Int((abs(rate) * scale).rounded()))
        guard magnitude > 0 else { return 0 }
        return rate > 0 ? magnitude | 0x8000 : magnitude
    }

    /// Inverse of `encode`. The estimate is the integral of admitted speeds, not a measured joint.
    private static func countsPerSecond(_ register: Int) -> Double {
        let magnitude = Double(register & 0x7FFF)
        let reverse = register & 0x8000 != 0
        let rate = magnitude / scale
        return reverse ? rate : -rate
    }

    private static func forearmLevel() throws -> NexArmPacket {
        let home = NexArmJointCommand.armHome
        let options = try NexArmMotorOptions(speed: 400, acceleration: 30)
        return try NexArmMotorCommands.simultaneous([
            try NexArmMotorCommands.move(motor: 2, target: home[1], options: options),
            try NexArmMotorCommands.move(motor: 3, target: home[2], options: options),
        ])
    }

    private static let stopped = try! NexArmMotorCommands.trackingSpeeds(base: 0, pitch: 0)

    private static let engage: [NexArmPacket] = try! [1, 4].flatMap { motor in
        [
            try NexArmMotorCommands.trackingTorque(motor: motor, enabled: false),
            try NexArmMotorCommands.trackingMode(motor: motor, closedLoopSpeed: true),
            try NexArmMotorCommands.trackingSpeed(motor: motor, speed: 0),
            try NexArmMotorCommands.trackingTorque(motor: motor, enabled: true),
        ]
    }

    private static let disengage: [NexArmPacket] = try! [1, 4].flatMap { motor in
        [
            try NexArmMotorCommands.trackingMode(motor: motor, closedLoopSpeed: false),
            try NexArmMotorCommands.trackingTorque(motor: motor, enabled: true),
        ]
    }

    private static func legal(_ count: Int, motor: Int) -> Bool {
        NexArmJogPlanner.limits[motor - 1].contains(count)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
