import Foundation
import FunctionContracts
import PlatformKit

extension NexArmMotionPlan.Step {
    public func options(for motor: Int) throws -> NexArmMotorOptions {
        guard targets[motor] != nil else { throw NexArmExecutionError.invalidArguments }
        let p = packet.payload
        if targets.count == 1, packet.command == 3 {
            return try NexArmMotorOptions(speed: Int(p[6]) | Int(p[7]) << 8, acceleration: Int(p[1]))
        }
        guard let offset = stride(from: 2, to: p.count, by: 8).first(where: { Int(p[$0]) == motor }) else {
            throw NexArmExecutionError.invalidArguments
        }
        return try NexArmMotorOptions(
            speed: Int(p[offset + 6]) | Int(p[offset + 7]) << 8, acceleration: Int(p[offset + 1]))
    }
}
