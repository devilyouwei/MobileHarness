import ActionRuntime
import Foundation
import PlatformKit

/// Finite immutable plan: lock scope is validated against every addressed motor before sending.
public struct NexArmMotionPlan: Sendable {
    public struct Step: Sendable {
        public let packet: NexArmPacket
        public let targets: [Int: Int]
    }
    public let lockedMotors: Set<Int>
    public let steps: [Step]
    public init(lockedMotors: Set<Int>, frames: [NexArmGesture.TestFrame]) throws {
        guard !lockedMotors.isEmpty, lockedMotors.isSubset(of: Set(1...6)), (1...20).contains(frames.count) else {
            throw NexArmError.invalidMotion
        }
        self.lockedMotors = lockedMotors
        steps = try frames.map { frame in
            guard let targets = frame.packet.motorTargets,
                Set(targets.keys).isSubset(of: lockedMotors)
            else { throw NexArmError.invalidMotion }
            return Step(packet: frame.packet, targets: targets)
        }
        guard Set(steps.flatMap { $0.targets.keys }) == lockedMotors else { throw NexArmError.invalidMotion }
    }
    public init(groups: [[NexArmPacket]]) throws {
        guard (1...20).contains(groups.count) else { throw NexArmError.invalidMotion }
        let packets = try groups.map { try NexArmMotorCommands.simultaneous($0) }
        let motors = Set(packets.flatMap { $0.motorTargets?.keys.map { $0 } ?? [] })
        try self.init(lockedMotors: motors, frames: packets.map { .init(packet: $0, milliseconds: 1000) })
    }
    public func configured(speed: Int, acceleration: Int) throws -> Self {
        let options = try NexArmMotorOptions(speed: speed, acceleration: acceleration)
        let frames = try steps.map { step in
            let packet: NexArmPacket
            if step.targets.count == 1, let target = step.targets.first {
                packet = try NexArmMotorCommands.move(motor: target.key, target: target.value, options: options)
            } else {
                var payload = step.packet.payload
                for offset in stride(from: 2, to: payload.count, by: 8) {
                    payload[offset + 1] = UInt8(acceleration)
                    payload[offset + 6] = UInt8(speed & 255)
                    payload[offset + 7] = UInt8(speed >> 8)
                }
                packet = try NexArmPacket(id: step.packet.id, command: step.packet.command, payload: payload)
            }
            return NexArmGesture.TestFrame(packet: packet, milliseconds: 1000)
        }
        return try Self(lockedMotors: lockedMotors, frames: frames)
    }

}

/// Fresh encoder feedback determines progress; there is no nominal-duration gate.
public struct NexArmSegmentTracker: Sendable {
    public enum Outcome: Equatable, Sendable { case waiting, arrived, unreached, timedOut }
    private let targets: [Int: Int]
    private let policy: NexArmMotorCompletion?
    private let started: ContinuousClock.Instant
    private let deadline: ContinuousClock.Instant
    private var lastSample: ContinuousClock.Instant?
    private var anchor: [Int: Int] = [:]
    private var stableSince: ContinuousClock.Instant?
    private var sampleCount = 0
    private var atTarget = false
    public init(
        targets: [Int: Int], started: ContinuousClock.Instant, deadline: ContinuousClock.Instant,
        policy: NexArmMotorCompletion? = nil
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
