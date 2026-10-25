import Foundation

extension UIActions {
    public enum VoiceState: String, Sendable { case listening, hearing, processing }

    /// Screen-space target: -1 left/up, +1 right/down; zero looks straight ahead.
    public struct Gaze: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }
    public enum GazeError: Error, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidTarget
        public var executionFailureCode: ActionExecutionFailureCode { .invalidArguments }
    }

    public enum PoseError: Error, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidPayload
        public var executionFailureCode: ActionExecutionFailureCode { .invalidArguments }
    }

    public enum PresentationError: Error, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidText
        case invalidCall
        public var executionFailureCode: ActionExecutionFailureCode { .invalidArguments }
    }
}
