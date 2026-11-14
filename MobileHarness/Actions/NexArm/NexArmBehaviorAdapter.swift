import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import PlatformKit
import StorageCore
import UI

/// Host adaptation only; gesture/execution business policy remains in Actions.
@MainActor
public struct NexArmBehaviorAdapter {
    public let bluetooth: BluetoothWorkflow
    public let activity: any ExecutionFailureReporting
    public init(bluetooth: BluetoothWorkflow, activity: any ExecutionFailureReporting) {
        self.bluetooth = bluetooth
        self.activity = activity
    }
    public func aim(_ base: Double, _ pitch: Double, _ invocation: any FunctionInput) async throws {
        do {
            try await bluetooth.aim(
                base: base, pitch: pitch,
                origin: .init(
                    source: invocation.context.source, sessionID: invocation.context.sessionID,
                    inputID: invocation.context.inputID, callID: invocation.executionID)
            ) { [activity] failure in
                await activity.recordFailure(
                    title: "NexArm.Tracking.aim", source: failure.origin?.source ?? "Continuous control",
                    message: failure.message,
                    failureCode: failure.code,
                    context: .init(
                        workerID: failure.workerID, sessionID: failure.origin?.sessionID,
                        inputID: failure.origin?.inputID, callID: failure.origin?.callID))
            }
        } catch let error as NexArmExecutionError {
            throw ActionExecutionFailure(
                code: .init(rawValue: error.actionExecutionFailure.rawValue),
                message: ActionReport.description(for: error))
        }
    }
    public func gesture(_ request: NexArmActions.GestureRequest, _ invocation: any FunctionInput) async throws {
        let reports = ActionReportStore()
        do {
            switch request.gesture {
            case .reset:
                try await bluetooth.resetArm(
                    speed: request.speed, acceleration: request.acceleration,
                    recordReport: { try await reports.record($0) })
            case .moveMotor, .resetMotor:
                guard let motor = request.motor else { throw NexArmExecutionError.invalidArguments }
                try await bluetooth.moveMotor(
                    id: motor, target: request.target, deltaDegrees: request.deltaDegrees, speed: request.speed,
                    acceleration: request.acceleration, recordReport: { try await reports.record($0) })
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
                default: throw NexArmExecutionError.invalidArguments
                }
                try await bluetooth.performGesture(
                    gesture, repetitions: request.repetitions,
                    speed: request.speed, acceleration: request.acceleration,
                    recordReport: { try await reports.record($0) })
            }
        } catch {
            if let report = await reports.snapshot() {
                try await invocation.results.record(report.recordingFailure(error))
                if error is CancellationError { throw error }
                return
            }
            throw error
        }
        if let report = await reports.snapshot() { try await invocation.results.record(report) }
    }
    public func shakeBase(_ cycles: Int, _ invocation: any FunctionInput) async throws {
        let reports = ActionReportStore()
        do {
            let args = ActionArguments(invocation.call.parameters)
            let speed =
                try invocation.call.parameters["speed"] == nil
                ? NexArmDeviceLimits.defaultSpeed : args.requiredInt("speed", range: NexArmDeviceLimits.speed)
            let acceleration =
                try invocation.call.parameters["acceleration"] == nil
                ? NexArmDeviceLimits.defaultAcceleration
                : args.requiredInt("acceleration", range: NexArmDeviceLimits.acceleration)
            try await bluetooth.performGesture(
                .baseSway, repetitions: cycles, speed: speed, acceleration: acceleration,
                recordReport: { try await reports.record($0) })
        } catch {
            if let report = await reports.snapshot() {
                try await invocation.results.record(report.recordingFailure(error))
                if error is CancellationError { throw error }
                return
            }
            throw error
        }
        if let report = await reports.snapshot() { try await invocation.results.record(report) }
    }
}
