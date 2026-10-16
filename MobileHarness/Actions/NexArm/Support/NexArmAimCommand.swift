import Foundation
import PlatformKit

/// Tracking command for motors 1 and 4. Shoulder and elbow stay on one position-mode preparation.
/// After that preparation, motors 1 and 4 use closed-loop speed. A sent packet is not physical arrival.
public struct NexArmAimCommand: Sendable {
    public struct Command: Sendable, Equatable {
        public let packet: NexArmPacket
        public let levelsForearm: Bool
        fileprivate let step: Step
        fileprivate let time: ContinuousClock.Instant
    }

    private enum Step: Equatable, Sendable {
        case level
        case engage(Int)
        case speed(baseSpeed: Int, pitchSpeed: Int, base: Int, pitch: Int)
    }

    private var seeded = false
    private var originBase = 0
    private var originPitch = 0
    private var lastBase = 0
    private var lastPitch = 0
    private var forearmAdmitted = false
    private var engageIndex = 0
    private var speedAdmitted = false
    private var admittedTime: ContinuousClock.Instant?
    private var lastSpeedBase = 0
    private var lastSpeedPitch = 0
    private var pending: Command?
    private var modeOpen = false

    public init() {}

    /// First estimate of where the two axes already are. Later calls keep that estimate.
    public mutating func seed(base: Int, pitch: Int) throws {
        guard !seeded else { return }
        guard Self.legal(base, motor: 1), Self.legal(pitch, motor: 4) else {
            throw NexArmExecutionError.invalidArguments
        }
        originBase = base
        originPitch = pitch
        lastBase = base
        lastPitch = pitch
        seeded = true
    }

    public mutating func reset() {
        self = NexArmAimCommand()
    }

    /// The next packet. Nil means the admitted speed already matches this target.
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
        let speeds = registerSpeeds(base: base, pitch: pitch, at: time)
        if let pending, case .speed(let heldBase, let heldPitch, _, _) = pending.step,
            heldBase == speeds.base, heldPitch == speeds.pitch
        {
            return pending
        }
        pending = nil
        if speeds.base == 0, speeds.pitch == 0, !speedAdmitted { return nil }
        guard !speedAdmitted || speeds.base != lastSpeedBase || speeds.pitch != lastSpeedPitch else { return nil }
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
            lastSpeedBase = baseSpeed
            lastSpeedPitch = pitchSpeed
            lastBase = base
            lastPitch = pitch
            admittedTime = command.time
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
        let holdBase = Self.legal(base, motor: 1) ? base : lastBase
        let holdPitch = Self.legal(pitch, motor: 4) ? pitch : lastPitch
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

    private func registerSpeeds(base: Int, pitch: Int, at time: ContinuousClock.Instant) -> (base: Int, pitch: Int) {
        let elapsed = admittedTime.map { min(0.5, max(0.02, Self.seconds(time - $0))) } ?? 0.2
        return (
            Self.encode(delta: base - lastBase, elapsed: elapsed),
            Self.encode(delta: pitch - lastPitch, elapsed: elapsed))
    }

    /// Positive speed magnitude with bit 15 clear decreases the encoder count.
    private static func encode(delta: Int, elapsed: Double) -> Int {
        guard elapsed > 0 else { return 0 }
        let magnitude = min(600, Int((abs(Double(delta) / elapsed) * 2.2).rounded()))
        guard magnitude > 0 else { return 0 }
        return delta > 0 ? magnitude | 0x8000 : magnitude
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
