import Foundation
import PlatformKit

/// Metadata available before device admission. Actual per-motor deadlines use live feedback.
enum NexArmRegistration {
    static func resources(_ call: ActionRequest) throws -> Set<ActionResource> {
        let motors: Set<Int>
        switch call.actionPath.function {
        case "nodHead": motors = [4]
        case "shakeHead": motors = [5]
        case "moveMotor", "resetMotor":

            guard let raw = call.parameters["motor"], let motor = Int(raw), (1...6).contains(motor) else { return [] }
            motors = [motor]
        default: motors = Set(1...5)
        }
        return Set(motors.map { ActionResource(rawValue: "nexarm.motor.\($0)") })
    }
    static func budget(_ call: ActionRequest) throws -> ActionExecutionBudget {
        func value(_ name: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = call.parameters[name] else { return fallback }
            guard let value = Int(raw), range.contains(value) else { throw NexArmError.invalidMotion }
            return value
        }
        let options = try NexArmMotorOptions(
            speed: value("speed", fallback: 1400, range: 1...1400),
            acceleration: value("acceleration", fallback: 30, range: 1...254))
        let cycles: Int
        do {
            cycles = try value(call.actionPath.function == "waveWrist" ? "count" : "cycles", fallback: 1, range: 1...3)
        } catch {
            switch call.actionPath.function {
            case "nodHead": throw NexArmActions.NodHeadError.invalidRepetitions
            case "shakeHead": throw NexArmActions.ShakeHeadError.invalidRepetitions
            case "waveWrist": throw NexArmActions.WaveWristError.invalidRepetitions
            case "lookAround": throw NexArmActions.LookAroundError.invalidRepetitions
            case "celebrate": throw NexArmActions.CelebrateError.invalidRepetitions
            case "dance": throw NexArmActions.DanceError.invalidRepetitions
            case "shakeBase": throw NexArmActions.ShakeError.invalidCycles
            default: throw error
            }
        }
        let steps: Int
        switch call.actionPath.function {
        case "reset", "resetMotor", "moveMotor": steps = 1
        case "nodHead", "shakeHead": steps = 1 + 5 * cycles
        case "dance": steps = 2 + 6 * cycles
        case "celebrate", "waveWrist": steps = 2 + 4 * cycles
        case "tiltWrist": steps = 3
        case "lookAround": steps = 2 + 3 * cycles
        default: steps = 2 + 3 * cycles
        }
        let ids = try resources(call).compactMap { Int($0.rawValue.split(separator: ".").last ?? "") }
        let children = ids.map { motor in
            let limits = NexArmMotorCommands.positionLimits[motor - 1]
            return NexArmMotorProfiles.budget(motor: motor, from: nil, target: limits.upperBound, options: options)
        }
        // Unknown live pose/IK before admission: reserve maximum legal travel per group.
        // Device setup and cooperative cleanup get 5s total; queue time is excluded.
        let expected = children.map(\.expectedMilliseconds).max() ?? 0
        let maximum = children.map(\.timeoutMilliseconds).max() ?? 0
        return try ActionExecutionBudget(
            expected: .milliseconds(expected * steps), timeout: .milliseconds((maximum + 1000) * steps + 5000))
    }
}
