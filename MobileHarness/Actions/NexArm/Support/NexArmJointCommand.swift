import Foundation
import PlatformKit

/// Five arm axes and one motors-1–5 aim packet. The suction cup occupies the gripper and is not addressed.
/// Joint order: shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll.
public enum NexArmJointCommand {
    public static let countsPerRadian = 4096.0 / (2 * Double.pi)
    /// Nominal duration used only to choose a legal motor speed. It is not a measured travel time.
    public static let aimMilliseconds = 200
    /// Production arm rest. The 2026-10-01 Bluetooth read sat on this pose; the gripper encoder is excluded.
    public static let armHome: [Int] = [2048, 2087, 1198, 1238, 2048]

    /// Logical 0 is each joint's arm-home count. Positive radians increase the raw count.
    public static func positions(base: Double, pitch: Double) throws -> [Int] {
        guard base.isFinite, pitch.isFinite, abs(base) <= 4 * .pi, abs(pitch) <= 4 * .pi else {
            throw NexArmControlError.invalidAngle
        }
        var positions = armHome
        positions[0] = raw(armHome[0], offset: base, joint: 0)
        positions[3] = raw(armHome[3], offset: pitch, joint: 3)
        return positions
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
