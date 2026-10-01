import Foundation

extension NexArmActions {
    public enum Gesture: Sendable, Equatable {
        case nod, shakeHead, wave, tiltLeft, tiltRight, lookAround, celebrate, dance, reset, moveMotor, resetMotor
    }
    public struct GestureRequest: Sendable, Equatable {
        public let gesture: Gesture
        public let repetitions: Int
        public let motor: Int?
        public let target: Int?
        public let speed: Int
        public let acceleration: Int
        public init(
            gesture: Gesture, repetitions: Int, motor: Int? = nil, target: Int? = nil, speed: Int = 1400,
            acceleration: Int = 30
        ) {
            self.motor = motor
            self.target = target
            self.speed = speed
            self.acceleration = acceleration
            self.gesture = gesture
            self.repetitions = repetitions
        }
    }
}

extension NexArmActions {
    public enum NodHeadError: LocalizedError, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "点头次数必须是 1 到 3 的整数" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum ShakeHeadError: LocalizedError, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "摇头次数必须是 1 到 3 的整数" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum WaveWristError: LocalizedError, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "挥手次数必须是 1 到 3 的整数" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum TiltDirection: String, Sendable { case left, right }

    public enum TiltWristError: LocalizedError, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidDirection
        public var errorDescription: String? { "歪头方向必须是左或右" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum LookAroundError: LocalizedError, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "张望次数必须是 1 到 3 的整数" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum CelebrateError: LocalizedError, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "庆祝次数必须是 1 到 3 的整数" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum DanceError: LocalizedError, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "跳舞次数必须是 1 到 3 的整数" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

    public enum ShakeError: LocalizedError, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidCycles
        public var errorDescription: String? { "晃动次数必须是 1 到 3 的整数" }
        public var actionExecutionFailure: ActionFailure { .invalidArguments }
    }

}
