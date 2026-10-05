import ActionRuntime
import Foundation
import PlatformKit

/// Action policy in native register units. Never writes servo calibration registers.
public enum NexArmMotorProfiles {
    public struct Profile: Sendable {
        public let tolerance: Int
    }
    public struct Budget: Sendable {
        public let expectedMilliseconds: Int
        public let timeoutMilliseconds: Int
        public let offTargetMilliseconds: Int
    }
    // See README measurement record. These are arrival regions, not accuracy guarantees.
    public static func profile(for motor: Int) -> Profile {
        switch motor {
        case 1: Profile(tolerance: 16)
        case 2: Profile(tolerance: 20)
        case 3: Profile(tolerance: 56)
        case 4: Profile(tolerance: 32)
        case 5: Profile(tolerance: 16)
        default: Profile(tolerance: 24)
        }
    }
    public static func budget(motor: Int, from: Int?, target: Int, options: NexArmMotorOptions) -> Budget {
        let limits = NexArmMotorCommands.positionLimits[min(6, max(1, motor)) - 1]
        let distance =
            from.map { abs(target - $0) } ?? max(abs(target - limits.lowerBound), abs(target - limits.upperBound))
        // Conservative empirical envelope, not an undocumented physical acceleration conversion.
        // 80-count trials at speed400/800/1400, acceleration30/50 took roughly 0.25–0.50s.
        let ramp = 0.4 * sqrt(30.0 / Double(options.acceleration))
        let expected = Double(distance) / Double(options.speed) + ramp + 0.2
        let stationary = max(0.6, 8.0 / Double(options.speed) + ramp)
        return Budget(
            expectedMilliseconds: Int(ceil(expected * 1000)),
            timeoutMilliseconds: Int(ceil((3 * expected + 1.2) * 1000)),
            offTargetMilliseconds: Int(ceil(stationary * 1000)))
    }
}

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

extension NexArmMotionPlan {
    /// Execution uses fresh current positions again for each group; this estimate uses preceding targets.
    public func executionBudget(from positions: [Int: Int]) throws -> ActionExecutionBudget {
        var positions = positions
        var groups: [ActionExecutionBudget] = []
        for step in steps {
            let children = try step.targets.map { motor, target in
                let budget = NexArmMotorProfiles.budget(
                    motor: motor, from: positions[motor], target: target, options: try step.options(for: motor))
                return try ActionExecutionBudget(
                    expected: .milliseconds(budget.expectedMilliseconds),
                    timeout: .milliseconds(budget.timeoutMilliseconds + 1000))
            }
            groups.append(try .parallel(children))
            positions.merge(step.targets) { _, next in next }
        }
        return try .sequence(groups)
    }
}
