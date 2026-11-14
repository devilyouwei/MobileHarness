import Foundation
import FunctionContracts
import PlatformKit

extension NexArmActions {
    public enum Gesture: Sendable, Equatable {
        case nod, shakeHead, wave, tiltLeft, tiltRight, lookAround, celebrate, dance, reset, moveMotor, resetMotor
    }
    public struct GestureRequest: Sendable, Equatable {
        public let gesture: Gesture
        public let repetitions: Int
        public let motor: Int?
        public let target: Int?
        public let deltaDegrees: Double?
        public let speed: Int
        public let acceleration: Int
        public init(
            gesture: Gesture, repetitions: Int, motor: Int? = nil, target: Int? = nil, deltaDegrees: Double? = nil,
            speed: Int = NexArmDeviceLimits.defaultSpeed,
            acceleration: Int = NexArmDeviceLimits.defaultAcceleration
        ) {
            self.motor = motor
            self.target = target
            self.deltaDegrees = deltaDegrees
            self.speed = speed
            self.acceleration = acceleration
            self.gesture = gesture
            self.repetitions = repetitions
        }
    }
}

extension NexArmActions {
    public enum NodHeadError: LocalizedError, Equatable, Sendable, ActionReportFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "Nod repetitions must be an integer from 1 to 3" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum ShakeHeadError: LocalizedError, Equatable, Sendable, ActionReportFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "Head shake repetitions must be an integer from 1 to 3" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum WaveWristError: LocalizedError, Equatable, Sendable, ActionReportFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "Wave repetitions must be an integer from 1 to 3" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum TiltDirection: String, Sendable { case left, right }

    public enum TiltWristError: LocalizedError, Equatable, Sendable, ActionReportFailureProviding {
        case invalidDirection
        public var errorDescription: String? { "Head tilt direction must be left or right" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum LookAroundError: LocalizedError, Equatable, Sendable, ActionReportFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "Look-around repetitions must be an integer from 1 to 3" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum CelebrateError: LocalizedError, Equatable, Sendable, ActionReportFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "Celebration repetitions must be an integer from 1 to 3" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum DanceError: LocalizedError, Equatable, Sendable, ActionReportFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "Dance repetitions must be an integer from 1 to 3" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum ShakeError: LocalizedError, Equatable, Sendable, ActionReportFailureProviding {
        case invalidCycles
        public var errorDescription: String? { "Sway repetitions must be an integer from 1 to 3" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

}

/// NexArm result vocabulary, transported opaquely by ActionRuntime.
extension ActionReport.Entry.Code {
    public static let targetNotReached = Self(rawValue: "targetNotReached")
    public static let feedbackLost = Self(rawValue: "feedbackLost")
    public static let disconnected = Self(rawValue: "disconnected")
    public static let admissionFailed = Self(rawValue: "admissionFailed")
    public static let feedbackFailed = Self(rawValue: "feedbackFailed")
    public static let sendingFailed = Self(rawValue: "sendingFailed")
}

extension NexArmActions {
    public enum AimError: LocalizedError, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidAngle
        public var executionFailureCode: ActionExecutionFailureCode { .invalidArguments }
        public var errorDescription: String? { "Invalid tracking target angle" }
    }
}
