import Foundation
import FunctionContracts
import PlatformKit

/// Finite immutable plan: lock scope is validated against every addressed motor before sending.
public struct NexArmMotionPlan: Sendable {
    public struct Step: Sendable {
        public let packet: NexArmPacket
        public let targets: [Int: Int]
        public let milliseconds: Int
    }
    public let lockedMotors: Set<Int>
    public let steps: [Step]
    public init(lockedMotors: Set<Int>, frames: [NexArmGesture.TestFrame]) throws {
        guard !lockedMotors.isEmpty, lockedMotors.isSubset(of: Set(1...6)), (1...20).contains(frames.count) else {
            throw NexArmExecutionError.invalidArguments
        }
        self.lockedMotors = lockedMotors
        steps = try frames.map { frame in
            guard let targets = frame.packet.motorTargets,
                Set(targets.keys).isSubset(of: lockedMotors)
            else { throw NexArmExecutionError.invalidArguments }
            guard (1...10_000).contains(frame.milliseconds) else { throw NexArmExecutionError.invalidArguments }
            return Step(packet: frame.packet, targets: targets, milliseconds: frame.milliseconds)
        }
        guard Set(steps.flatMap { $0.targets.keys }) == lockedMotors else {
            throw NexArmExecutionError.invalidArguments
        }
    }
    public init(groups: [[NexArmPacket]]) throws {
        guard (1...20).contains(groups.count) else { throw NexArmExecutionError.invalidArguments }
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
            return NexArmGesture.TestFrame(packet: packet, milliseconds: step.milliseconds)
        }
        return try Self(lockedMotors: lockedMotors, frames: frames)
    }

}

/// Compatibility name for the SDK-owned position observer.
public typealias NexArmSegmentTracker = NexArmPositionObservation
