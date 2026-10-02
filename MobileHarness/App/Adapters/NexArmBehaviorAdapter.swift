import ActionRuntime
import Actions
import AppWorkflows
import Foundation
import PlatformKit

/// Host adaptation only; gesture/execution business policy remains in Actions.
@MainActor
struct NexArmBehaviorAdapter {
    let bluetooth: BluetoothWorkflow
    func gesture(_ request: NexArmActions.GestureRequest, _ invocation: ActionInvocation) async throws {
        let composition = try ActionComposition(
            .action("gesture", [], maximumResults: 100) {
                do {
                    switch request.gesture {
                    case .reset:
                        try await bluetooth.resetArm(speed: request.speed, acceleration: request.acceleration)
                    case .moveMotor, .resetMotor:
                        guard let motor = request.motor else { throw NexArmError.invalidMotion }
                        try await bluetooth.moveMotor(
                            id: motor, target: request.target, speed: request.speed,
                            acceleration: request.acceleration)
                    default:
                        let gesture: NexArmGesture
                        switch request.gesture {
                        case .nod: gesture = .nod
                        case .shakeHead: gesture = .shakeHead
                        case .wave: gesture = .wave
                        case .tiltLeft: gesture = .tiltLeft
                        case .tiltRight: gesture = .tiltRight
                        case .lookAround: gesture = .lookAround
                        case .celebrate: gesture = .celebrate
                        case .dance: gesture = .dance
                        default: throw NexArmError.invalidMotion
                        }
                        try await bluetooth.performGesture(
                            gesture, repetitions: request.repetitions,
                            speed: request.speed, acceleration: request.acceleration)
                    }
                } catch {
                    if let report = await bluetooth.lastActionReport {
                        return .report(report)
                    }
                    throw error
                }
                if let report = await bluetooth.lastActionReport { return .report(report) }
                return .completed
            })
        try await invocation.results.record(composition.run())
    }
    func shakeBase(_ cycles: Int, _ invocation: ActionInvocation) async throws {
        do {
            let args = ActionArguments(invocation.call.parameters)
            let speed =
                try invocation.call.parameters["speed"] == nil
                ? 1400 : args.requiredInt("speed", range: 1...1400)
            let acceleration =
                try invocation.call.parameters["acceleration"] == nil
                ? 30 : args.requiredInt("acceleration", range: 1...254)
            try await bluetooth.performGesture(
                .baseSway, repetitions: cycles, speed: speed, acceleration: acceleration)
        } catch {
            if let report = await bluetooth.lastActionReport {
                try await invocation.results.record(report)
                if error is CancellationError { throw error }
                return
            }
            throw error
        }
        if let report = await bluetooth.lastActionReport { try await invocation.results.record(report) }
    }
}
