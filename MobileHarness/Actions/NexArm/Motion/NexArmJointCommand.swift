import Foundation
import PlatformKit

/// Five arm axes and one motors-1–5 aim packet. The suction cup occupies the gripper and is not addressed.
/// Joint order: shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll.
public enum NexArmJointCommand {
    public static let countsPerRadian = 4096.0 / (2 * Double.pi)
    /// Nominal duration used only to choose a legal motor speed. It is not a measured travel time.
    public static let aimMilliseconds = 200
    /// Tracking rest and highest camera position, read over Bluetooth on 2026-10-03 (X299 Z327 mm, end pitch -1.9°).
    /// Tracking only; ordinary reset uses NexArmGesture.referenceHomeJoints.
    /// The gripper encoder (1630) is excluded: the suction cup occupies it.
    public static let armHome: [Int] = [2047, 2087, 1984, 2045, 2048]
    /// Measured 2026-10-03: with the wrist fixed, shoulder_lift + elbow_flex of 4067…4071 holds the forearm level.
    /// Each 11.3 counts of difference tilts it 1°.
    public static var forearmLevelSum: Int { armHome[1] + armHome[2] }
    /// Lowest shoulder_lift tracking may use (Z about 100 mm). The measured physical low is 1038 (Z 62 mm).
    public static let reachLiftMinimum = 1150
    /// Wrist pitch (radians, camera looking down) at which the arm starts to extend, and where it is fully extended.
    public static let reachPitchThreshold = 0.25
    public static let reachPitchLimit = 0.7

    /// Logical 0 is each joint's arm-home count. Positive radians increase the raw count.
    /// Shoulder lift follows wrist pitch and the elbow levels the forearm; wrist roll and the gripper stay put.
    public static func positions(base: Double, pitch: Double) throws -> [Int] {
        guard base.isFinite, pitch.isFinite, abs(base) <= 4 * .pi, abs(pitch) <= 4 * .pi else {
            throw NexArmControlError.invalidAngle
        }
        var positions = armHome
        positions[0] = raw(armHome[0], offset: base, joint: 0)
        positions[3] = raw(armHome[3], offset: pitch, joint: 3)
        positions[1] = reachLift(pitch: pitch)
        positions[2] = forearmLevelSum - positions[1]
        return positions
    }

    /// Looking down far enough extends the arm forward, which lowers the camera. The rest is already the highest
    /// position, so looking up never raises the shoulder above it.
    public static func reachLift(pitch: Double) -> Int {
        let travel = Double(armHome[1] - reachLiftMinimum)
        let span = reachPitchLimit - reachPitchThreshold
        let fraction = min(1, max(0, (pitch - reachPitchThreshold) / span))
        return armHome[1] - Int((travel * fraction).rounded())
    }

    /// Broadcast servo write listing IDs 1...5. No gripper byte is present.
    /// Speed is based on the preceding target, preserving slow incremental tracking away from home.
    public static func packet(positions: [Int], previous: [Int]) throws -> NexArmPacket {
        guard positions.count == 5, previous.count == 5,
            zip(positions, NexArmMotorCommands.positionLimits.prefix(5)).allSatisfy({ $1.contains($0) }),
            zip(previous, NexArmMotorCommands.positionLimits.prefix(5)).allSatisfy({ $1.contains($0) })
        else { throw NexArmControlError.invalidPosition }
        let atoms = try positions.enumerated().map { index, position in
            let distance = abs(position - previous[index])
            let speed = max(1, min(700, Int(ceil(Double(distance) * 1250 / Double(aimMilliseconds)))))
            return try NexArmMotorCommands.move(
                motor: index + 1, target: position, options: NexArmMotorOptions(speed: speed))
        }
        return try NexArmMotorCommands.simultaneous(atoms)
    }

    public static func packet(positions: [Int]) throws -> NexArmPacket {
        try packet(positions: positions, previous: armHome)
    }

    public static func frame(positions: [Int]) throws -> [UInt8] {
        try packet(positions: positions).bytes
    }

    public static func aimPacket(base: Double, pitch: Double) throws -> NexArmPacket {
        try packet(positions: try positions(base: base, pitch: pitch))
    }

    public static func aimFrame(base: Double, pitch: Double) throws -> [UInt8] {
        try aimPacket(base: base, pitch: pitch).bytes
    }

    private static func raw(_ center: Int, offset: Double, joint: Int) -> Int {
        let value = Double(center) + offset * countsPerRadian
        let limit = NexArmMotorCommands.positionLimits[joint]
        return min(limit.upperBound, max(limit.lowerBound, Int(value.rounded())))
    }
}

public enum NexArmControlError: Error, Equatable, Sendable {
    case invalidAngle
    case invalidPosition
}

/// Elbow command that keeps the forearm level for a shoulder lift.
/// Measured 2026-10-03: when the elbow count rises (forearm lifts against gravity) it only starts after the command
/// leads it by about 40 counts and then stays about 40 short. Lowering is accurate. The lead is therefore added
/// while the lift target is extending and removed once it retracts.
public struct NexArmForearmLeveler: Sendable {
    public static let lead = 40
    public static let hysteresis = 6
    private var reference: Int?
    private var current = 0
    public init() {}

    public mutating func elbow(forLift lift: Int) -> Int {
        let level = NexArmJointCommand.forearmLevelSum - lift
        if let reference {
            if level >= reference + Self.hysteresis {
                current = Self.lead
                self.reference = level
            } else if level <= reference - Self.hysteresis {
                current = 0
                self.reference = level
            }
        } else {
            reference = level
        }
        let limits = NexArmMotorCommands.positionLimits[2]
        return min(limits.upperBound, max(limits.lowerBound, level + current))
    }
}
