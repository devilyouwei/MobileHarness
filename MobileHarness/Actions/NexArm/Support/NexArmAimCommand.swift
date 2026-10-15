import Foundation
import PlatformKit

/// One pan/tilt command for tracking. Motors 1 and 4 share a single admitted write.
/// The first admitted command also places motors 2 and 3 on the calibrated level rest.
/// Motor 5 is not addressed. A sent packet is not physical arrival.
public struct NexArmAimCommand: Sendable {
    public struct Parameters: Sendable, Equatable {
        /// Logical-target change, in encoder counts, required before another write.
        public var deadzoneCounts: Int
        /// Seconds of target velocity added ahead of the latest count.
        public var lookahead: Double
        /// Register speed is `distance / lookahead * speedScale`. Measured travel is slower than the register.
        public var speedScale: Double
        public var acceleration: Int
        public var minimumSpeed: Int
        public var maximumSpeed: Int

        public init(
            deadzoneCounts: Int = 12, lookahead: Double = 0.2, speedScale: Double = 2.2,
            acceleration: Int = 30, minimumSpeed: Int = 10, maximumSpeed: Int = 600
        ) {
            self.deadzoneCounts = deadzoneCounts
            self.lookahead = lookahead
            self.speedScale = speedScale
            self.acceleration = acceleration
            self.minimumSpeed = minimumSpeed
            self.maximumSpeed = maximumSpeed
        }

        /// Defaults from the 2026-10-13 BLE comparison: one packet per target, 12-count dead zone, 0.2 s lead.
        public static let tracking = Parameters()

        func validate() throws {
            guard (0...64).contains(deadzoneCounts), lookahead.isFinite, lookahead > 0, lookahead <= 1,
                speedScale.isFinite, speedScale > 0, speedScale <= 8,
                (1...254).contains(acceleration),
                (1...1400).contains(minimumSpeed), (1...1400).contains(maximumSpeed),
                minimumSpeed <= maximumSpeed
            else { throw NexArmExecutionError.invalidArguments }
        }
    }

    public struct Proposal: Sendable, Equatable {
        public let packet: NexArmPacket
        /// Latest requested counts. The dead zone compares these, not the led goals.
        public let baseTarget: Int
        public let pitchTarget: Int
        /// Counts written to the servos. The first sample has no lead.
        public let baseGoal: Int
        public let pitchGoal: Int
    }

    /// One native write. The first admitted command of a session also levels the forearm.
    public struct Command: Sendable, Equatable {
        public let packet: NexArmPacket
        public let levelsForearm: Bool
        fileprivate let aim: Proposal?
    }

    private var parameters: Parameters
    private var seeded = false
    private var originBase = 0
    private var originPitch = 0
    private var lastSentBase: Int?
    private var lastSentPitch: Int?
    private var lastGoalBase: Int?
    private var lastGoalPitch: Int?
    private var previousBase: Int?
    private var previousPitch: Int?
    private var sampleTime: ContinuousClock.Instant?
    private var pending: Proposal?
    private var forearmAdmitted = false

    public init(parameters: Parameters = .tracking) {
        self.parameters = parameters
    }

    /// First estimate of where the two axes already are. Later calls keep that estimate.
    public mutating func seed(base: Int, pitch: Int) throws {
        guard !seeded else { return }
        guard Self.legal(base, motor: 1), Self.legal(pitch, motor: 4) else {
            throw NexArmExecutionError.invalidArguments
        }
        originBase = base
        originPitch = pitch
        seeded = true
    }

    public mutating func reset() {
        self = NexArmAimCommand(parameters: parameters)
    }

    /// Nil when the logical target is still inside the dead zone.
    /// The same proposal is returned until `accept`; a newer target replaces an unadmitted one.
    public mutating func propose(base: Int, pitch: Int, at time: ContinuousClock.Instant) throws -> Proposal? {
        try parameters.validate()
        guard seeded, Self.legal(base, motor: 1), Self.legal(pitch, motor: 4) else {
            throw NexArmExecutionError.invalidArguments
        }
        if let pending, pending.baseTarget == base, pending.pitchTarget == pitch { return pending }
        pending = nil
        let sentBase = lastSentBase ?? originBase
        let sentPitch = lastSentPitch ?? originPitch
        guard
            abs(base - sentBase) >= parameters.deadzoneCounts
                || abs(pitch - sentPitch) >= parameters.deadzoneCounts
        else { return nil }
        let elapsed: Double
        let stepBase: Int
        let stepPitch: Int
        if let sampleTime, let previousBase, let previousPitch {
            elapsed = min(0.4, max(0.05, Self.seconds(time - sampleTime)))
            stepBase = base - previousBase
            stepPitch = pitch - previousPitch
        } else {
            elapsed = parameters.lookahead
            stepBase = 0
            stepPitch = 0
        }
        let baseGoal = Self.clamp(base + lead(stepBase, elapsed: elapsed), motor: 1)
        let pitchGoal = Self.clamp(pitch + lead(stepPitch, elapsed: elapsed), motor: 4)
        let estimatedBase = lastGoalBase ?? originBase
        let estimatedPitch = lastGoalPitch ?? originPitch
        let packet = try NexArmMotorCommands.simultaneous([
            try NexArmMotorCommands.move(
                motor: 1, target: baseGoal,
                options: try NexArmMotorOptions(
                    speed: speed(from: estimatedBase, to: baseGoal), acceleration: parameters.acceleration)),
            try NexArmMotorCommands.move(
                motor: 4, target: pitchGoal,
                options: try NexArmMotorOptions(
                    speed: speed(from: estimatedPitch, to: pitchGoal), acceleration: parameters.acceleration)),
        ])
        let proposal = Proposal(
            packet: packet, baseTarget: base, pitchTarget: pitch, baseGoal: baseGoal, pitchGoal: pitchGoal)
        previousBase = base
        previousPitch = pitch
        sampleTime = time
        pending = proposal
        return proposal
    }

    /// Pan/tilt, or only the forearm when pan/tilt is inside the dead zone and the level rest is not yet admitted.
    /// The first command that is admitted includes motors 2 and 3 at the calibrated rest.
    public mutating func command(base: Int, pitch: Int, at time: ContinuousClock.Instant) throws -> Command? {
        let aim = try propose(base: base, pitch: pitch, at: time)
        if forearmAdmitted {
            guard let aim else { return nil }
            return Command(packet: aim.packet, levelsForearm: false, aim: aim)
        }
        let level = try Self.forearmLevelMoves()
        if let aim {
            let packet = try NexArmMotorCommands.simultaneous(try Self.moves(in: aim.packet) + level)
            return Command(packet: packet, levelsForearm: true, aim: aim)
        }
        return Command(
            packet: try NexArmMotorCommands.simultaneous(level), levelsForearm: true, aim: nil)
    }

    public mutating func accept(_ proposal: Proposal) {
        guard pending == proposal else { return }
        lastSentBase = proposal.baseTarget
        lastSentPitch = proposal.pitchTarget
        lastGoalBase = proposal.baseGoal
        lastGoalPitch = proposal.pitchGoal
        pending = nil
    }

    public mutating func accept(_ command: Command) {
        if let aim = command.aim {
            guard pending == aim else { return }
            accept(aim)
        }
        if command.levelsForearm { forearmAdmitted = true }
    }

    /// Shoulder and elbow of the calibrated tracking rest. Their sum holds the forearm level.
    private static func forearmLevelMoves() throws -> [NexArmPacket] {
        let home = NexArmJointCommand.armHome
        let options = try NexArmMotorOptions(speed: 400, acceleration: 30)
        return [
            try NexArmMotorCommands.move(motor: 2, target: home[1], options: options),
            try NexArmMotorCommands.move(motor: 3, target: home[2], options: options),
        ]
    }

    private static func moves(in packet: NexArmPacket) throws -> [NexArmPacket] {
        guard let targets = packet.motorTargets else { throw NexArmExecutionError.invalidArguments }
        var moves: [NexArmPacket] = []
        for motor in targets.keys.sorted() {
            guard let target = targets[motor] else { throw NexArmExecutionError.invalidArguments }
            let start = try motorOffset(in: packet, motor: motor)
            let speed = Int(packet.payload[start + 6]) | Int(packet.payload[start + 7]) << 8
            let acceleration = Int(packet.payload[start + 1])
            moves.append(
                try NexArmMotorCommands.move(
                    motor: motor, target: target,
                    options: try NexArmMotorOptions(speed: speed, acceleration: acceleration)))
        }
        return moves
    }

    private static func motorOffset(in packet: NexArmPacket, motor: Int) throws -> Int {
        guard
            let start = stride(from: 2, to: packet.payload.count, by: 8).first(where: {
                packet.payload[$0] == UInt8(motor)
            })
        else { throw NexArmExecutionError.invalidArguments }
        return start
    }

    private func lead(_ step: Int, elapsed: Double) -> Int {
        guard step != 0, elapsed > 0 else { return 0 }
        let raw = Double(step) * parameters.lookahead / elapsed
        let limited = min(abs(raw), abs(Double(step)))
        return Int(copysign(limited, raw).rounded())
    }

    private func speed(from position: Int, to goal: Int) -> Int {
        let raw = Double(abs(goal - position)) / parameters.lookahead * parameters.speedScale
        return min(parameters.maximumSpeed, max(parameters.minimumSpeed, Int(raw.rounded())))
    }

    private static func legal(_ count: Int, motor: Int) -> Bool {
        NexArmJogPlanner.limits[motor - 1].contains(count)
    }

    private static func clamp(_ count: Int, motor: Int) -> Int {
        let limits = NexArmJogPlanner.limits[motor - 1]
        return min(limits.upperBound, max(limits.lowerBound, count))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
