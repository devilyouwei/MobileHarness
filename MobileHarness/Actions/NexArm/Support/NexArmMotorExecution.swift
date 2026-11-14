import Foundation
import FunctionContracts
import PlatformKit

/// Compatibility name for the SDK-owned feedback configuration.
public typealias NexArmMotorCompletion = NexArmFeedbackConfiguration

public struct NexArmMotorResult: Codable, Sendable, Equatable {
    public enum Failure: String, Codable, Sendable {
        case targetNotReached, timedOut, feedbackLost, disconnected, sendingFailed, admissionFailed, feedbackFailed,
            cancelled
    }
    public enum Outcome: String, CaseIterable, Codable, Sendable {
        case arrived, notReached, timedOut, cancelled, unconfirmed
    }
    /// Domain outcome only. Native/admission/transport detail remains in failure.
    public var outcome: Outcome {
        switch failure {
        case nil: started ? .arrived : .unconfirmed
        case .targetNotReached: .notReached
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .feedbackLost, .disconnected, .sendingFailed, .admissionFailed, .feedbackFailed: .unconfirmed
        }
    }
    public let step: Int
    public let motor: Int
    public let target: Int
    public let observed: Int?
    public let failure: Failure?
    public let started: Bool
}

/// Business execution failures, separate from device transport/protocol errors.
public enum NexArmActionError: Error, Equatable, Sendable {
    case targetsNotReached([Int])
    case motionTimedOut([Int])
    case moving, uncertainMotion
}

/// Reset is an Action operation: the caller selects the configured home.
public enum NexArmMotorReset {
    public static func reset(motor: Int, home: [Int: Int], options: NexArmMotorOptions) throws -> NexArmPacket {
        guard let target = home[motor] else { throw NexArmExecutionError.invalidArguments }
        return try NexArmMotorCommands.move(motor: motor, target: target, options: options)
    }
}

/// Invocation/admission errors owned by Actions; unrelated to Bluetooth diagnostic events.
public enum NexArmExecutionError: LocalizedError, Sendable, Equatable, ActionReportFailureProviding {
    case disconnected, busy, background, controlNotReady, feedbackTimeout
    case invalidArguments, unsupportedFirmware, firmwareUnavailable, admissionTimeout
    case resourceBusy
    case resourceUnavailable(String)
    public var actionExecutionFailure: ActionFailure {
        let identifier: String
        switch self {
        case .disconnected: identifier = "disconnected"
        case .busy: identifier = "busy"
        case .resourceBusy, .resourceUnavailable: identifier = "resourceUnavailable"
        case .background: identifier = "background"
        case .controlNotReady: identifier = "controlNotReady"
        case .feedbackTimeout: identifier = "feedbackTimeout"
        case .invalidArguments: identifier = "invalidArguments"
        case .unsupportedFirmware, .firmwareUnavailable: identifier = "unavailable"
        case .admissionTimeout: identifier = "admissionTimeout"
        }
        return ActionFailure(rawValue: identifier)
    }
    public var actionReportCode: ActionReport.Entry.Code {
        switch self {
        case .feedbackTimeout: .feedbackLost
        case .disconnected: .disconnected
        case .invalidArguments: .invalidArguments
        case .admissionTimeout: .timedOut
        case .busy, .controlNotReady, .background, .resourceBusy, .resourceUnavailable, .unsupportedFirmware,
            .firmwareUnavailable:
            .unavailable
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid motion arguments or execution plan"
        case .unsupportedFirmware: "The current firmware does not support this motion"
        case .firmwareUnavailable: "Firmware information is unavailable for this motion"
        case .admissionTimeout: "Motion admission timed out before command submission"
        case .disconnected: "Device operation is unavailable"
        case .busy: "The arm is completing another operation. Try again."
        case .resourceBusy: "Another operation is using the motors. Try again."
        case .resourceUnavailable(let reason): "Motor control resources unavailable: \(reason)"
        case .background: "Bring the app to the foreground to control the arm"
        case .feedbackTimeout: "Motion position feedback timed out before completion"
        case .controlNotReady: "The device is not ready for this operation"
        }
    }
}
