import Foundation
import FunctionContracts
import PlatformKit

/// Metadata available before device admission. Actual per-motor deadlines use live feedback.
enum NexArmRegistration {
    static func resources(_ call: FunctionRequest) throws -> Set<ActionResource> {
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
    static func budget(_ call: FunctionRequest) throws -> ActionExecutionBudget {
        func value(_ name: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = call.parameters[name] else { return fallback }
            guard let value = Int(raw), range.contains(value) else { throw NexArmExecutionError.invalidArguments }
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
        let gesture: NexArmGesture?
        switch call.actionPath.function {
        case "reset", "resetMotor", "moveMotor": gesture = nil
        case "nodHead": gesture = .nod
        case "shakeHead": gesture = .shakeHead
        case "dance": gesture = .dance
        case "celebrate": gesture = .celebrate
        case "waveWrist": gesture = .wave
        case "tiltWrist": gesture = .tiltLeft
        case "lookAround": gesture = .lookAround
        case "shakeBase": gesture = .baseSway
        default: throw NexArmExecutionError.invalidArguments
        }
        let steps: Int
        if let gesture {
            steps =
                try gesture.motorID != nil
                ? NexArmSimpleActions.frames(
                    gesture, home: NexArmGesture.referenceHomeJoints, repetitions: cycles
                ).count
                : gesture.cartesianPlaybackFrames(repetitions: gesture == .tiltLeft ? 1 : cycles).count
        } else {
            steps = 1
        }
        let ids = try resources(call).compactMap { Int($0.rawValue.split(separator: ".").last ?? "") }
        let children = try ids.map { motor in
            let limits = NexArmMotorCommands.positionLimits[motor - 1]
            let estimate = NexArmMotorProfiles.budget(
                motor: motor, from: nil, target: limits.upperBound, options: options)
            return try ActionExecutionBudget(
                expected: .milliseconds(estimate.expectedMilliseconds),
                timeout: .milliseconds(estimate.timeoutMilliseconds + 1000))
        }
        // Unknown live pose/IK before admission: reserve maximum legal travel per group.
        // Device setup and cooperative cleanup get 5s total; queue time is excluded.
        let group = try ActionExecutionBudget.parallel(children)
        let motion = try ActionExecutionBudget.sequence(Array(repeating: group, count: steps))
        return try ActionExecutionBudget.sequence([
            motion, ActionExecutionBudget(expected: .zero, timeout: .seconds(5)),
        ])
    }
}
