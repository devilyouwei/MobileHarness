import AgentCore
import Foundation

extension NexArmActions {
    public enum Gesture: Sendable, Equatable {
        case nod, shakeHead, wave, tiltLeft, tiltRight, lookAround, celebrate, dance
    }
    public struct GestureRequest: Sendable, Equatable {
        public let gesture: Gesture
        public let repetitions: Int
        public init(gesture: Gesture, repetitions: Int) {
            self.gesture = gesture
            self.repetitions = repetitions
        }
    }
}

extension NexArmActions.DanceError: LocalizedError, ActionExecutionFailureProviding {
    public var errorDescription: String? { "跳舞次数必须是 1 到 3 的整数" }
    public var actionExecutionFailure: ActionExecutionRecord.Failure { .invalidArguments }
}

extension NexArmActions.CelebrateError: LocalizedError, ActionExecutionFailureProviding {
    public var errorDescription: String? { "庆祝次数必须是 1 到 3 的整数" }
    public var actionExecutionFailure: ActionExecutionRecord.Failure { .invalidArguments }
}

extension NexArmActions.LookAroundError: LocalizedError, ActionExecutionFailureProviding {
    public var errorDescription: String? { "张望次数必须是 1 到 3 的整数" }
    public var actionExecutionFailure: ActionExecutionRecord.Failure { .invalidArguments }
}

extension NexArmActions.WaveWristError: LocalizedError, ActionExecutionFailureProviding {
    public var errorDescription: String? { "挥手次数必须是 1 到 3 的整数" }
    public var actionExecutionFailure: ActionExecutionRecord.Failure { .invalidArguments }
}

extension NexArmActions.ShakeError: LocalizedError, ActionExecutionFailureProviding {
    public var errorDescription: String? { "晃动次数必须是 1 到 3 的整数" }
    public var actionExecutionFailure: ActionExecutionRecord.Failure { .invalidArguments }
}

extension NexArmActions.TiltWristError: LocalizedError, ActionExecutionFailureProviding {
    public var errorDescription: String? { "歪头方向必须是左或右" }
    public var actionExecutionFailure: ActionExecutionRecord.Failure { .invalidArguments }
}
