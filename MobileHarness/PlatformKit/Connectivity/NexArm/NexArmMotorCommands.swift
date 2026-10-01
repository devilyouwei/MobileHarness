import Foundation

/// Hardware motion options use native encoder/register units, not guessed physical units.
public struct NexArmMotorOptions: Sendable, Equatable {
    public let speed: Int
    public let acceleration: Int
    public init(speed: Int = 1400, acceleration: Int = 30) throws {
        guard (1...1400).contains(speed), (1...254).contains(acceleration) else { throw NexArmError.invalidMotion }
        self.speed = speed
        self.acceleration = acceleration
    }
}
/// Encodes native position registers; no reset/home or gesture semantics.
public enum NexArmMotorCommands {
    public static let positionLimits = [210...3826, 200...3800, 968...3200, 728...3218, 908...3128, 1118...2828]
    public static func move(motor: Int, target: Int, options: NexArmMotorOptions) throws -> NexArmPacket {
        guard (1...6).contains(motor), positionLimits[motor - 1].contains(target) else {
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
        guard (1...6).contains(atoms.count), Set(atoms.map(\.id)).count == atoms.count,
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
