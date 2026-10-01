import Foundation

/// Five arm axes and one motors-1–5 aim packet. The suction cup occupies the gripper and is not addressed.
/// Joint order: shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll.
public enum NexArmJointCommand {
    public static let countsPerRadian = 4096.0 / (2 * Double.pi)
    /// Nominal duration used only to choose a legal motor speed. It is not a measured travel time.
    public static let aimMilliseconds = 800
    /// Phone joins this hotspot and keeps one TCP connection. The camera session does not open it.
    public static let wifiHost = "192.168.4.1"
    public static let wifiPort: UInt16 = 8080
    /// Production arm rest. The 2026-10-01 Bluetooth read sat on this pose; the gripper encoder is excluded.
    public static let armHome: [Int] = Array(NexArmJogPlanner.home.prefix(5))

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
    public static func frame(positions: [Int]) throws -> [UInt8] {
        guard positions.count == 5,
            zip(positions, NexArmJogPlanner.limits.prefix(5)).allSatisfy({ $1.contains($0) })
        else { throw NexArmControlError.invalidPosition }
        var payload: [UInt8] = [41, 7]
        for index in 0..<5 {
            let distance = abs(positions[index] - armHome[index])
            let speed = max(1, min(1400, Int(ceil(Double(distance) * 1250 / Double(aimMilliseconds)))))
            payload += [
                UInt8(index + 1), 30, UInt8(positions[index] & 255), UInt8(positions[index] >> 8), 0, 0,
                UInt8(speed & 255), UInt8(speed >> 8),
            ]
        }
        let packet = try NexArmPacket(id: 254, command: 131, payload: payload)
        guard packet.isArmControl else { throw NexArmControlError.invalidPosition }
        return packet.bytes
    }

    public static func aimFrame(base: Double, pitch: Double) throws -> [UInt8] {
        try frame(positions: try positions(base: base, pitch: pitch))
    }

    private static func raw(_ center: Int, offset: Double, joint: Int) -> Int {
        let value = Double(center) + offset * countsPerRadian
        let limit = NexArmJogPlanner.limits[joint]
        return min(limit.upperBound, max(limit.lowerBound, Int(value.rounded())))
    }
}

public enum NexArmControlError: Error, Equatable, Sendable {
    case invalidAngle
    case invalidPosition
}
