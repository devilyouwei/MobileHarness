import Foundation

/// Six raw joint positions and the reference driver's position-write frame.
/// Joint order: shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll, gripper.
public enum NexArmJointCommand {
    public static let writePositions: UInt8 = 97
    public static let provisionalHome = 2048
    public static let countsPerRadian = 4096.0 / (2 * Double.pi)
    /// Phone joins this hotspot and keeps one TCP connection. The camera session does not open it.
    public static let wifiHost = "192.168.4.1"
    public static let wifiPort: UInt16 = 8080

    /// Logical 0 is raw 2048. Positive radians increase the raw count. Values clamp to 0...4095.
    public static func positions(base: Double, pitch: Double) throws -> [Int] {
        guard base.isFinite, pitch.isFinite, abs(base) <= 4 * .pi, abs(pitch) <= 4 * .pi else {
            throw NexArmControlError.invalidAngle
        }
        var positions = Array(repeating: provisionalHome, count: 6)
        positions[0] = raw(provisionalHome, offset: base)
        positions[3] = raw(provisionalHome, offset: pitch)
        return positions
    }

    /// `FF FF FF LEN 97` plus twelve little-endian position bytes and the checksum.
    public static func frame(positions: [Int]) throws -> [UInt8] {
        guard positions.count == 6, positions.allSatisfy({ (0...4095).contains($0) }) else {
            throw NexArmControlError.invalidPosition
        }
        var parameters: [UInt8] = []
        parameters.reserveCapacity(12)
        for position in positions {
            parameters.append(UInt8(position & 0xFF))
            parameters.append(UInt8((position >> 8) & 0xFF))
        }
        return packet(command: writePositions, parameters: parameters)
    }

    public static func aimFrame(base: Double, pitch: Double) throws -> [UInt8] {
        try frame(positions: try positions(base: base, pitch: pitch))
    }

    private static func raw(_ center: Int, offset: Double) -> Int {
        let value = Double(center) + offset * countsPerRadian
        return min(4095, max(0, Int(value.rounded())))
    }

    private static func packet(command: UInt8, parameters: [UInt8]) -> [UInt8] {
        let identifier: UInt8 = 0xFF
        let length = UInt8(parameters.count + 2)
        var sum = Int(identifier) + Int(length) + Int(command)
        for byte in parameters { sum += Int(byte) }
        let checksum = UInt8(truncatingIfNeeded: ~sum)
        return [0xFF, 0xFF, identifier, length, command] + parameters + [checksum]
    }
}

public enum NexArmControlError: Error, Equatable, Sendable {
    case invalidAngle
    case invalidPosition
}
