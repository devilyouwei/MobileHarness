import ToolRuntime

extension UITools {
    public enum VoiceState: String, Sendable { case listening, hearing, processing }

    /// Screen-space target: -1 left/up, +1 right/down; zero looks straight ahead.
    public struct Gaze: Sendable, Equatable {
        public let x: Double
        public let y: Double
    }
    public enum GazeError: Error, Equatable, Sendable, ToolExecutionFailureProviding {
        case invalidTarget
        public var toolFailureCode: ToolResponse.FailureCode { .invalidArguments }
    }

    public enum PoseError: Error, Equatable, Sendable, ToolExecutionFailureProviding {
        case invalidPayload
        public var toolFailureCode: ToolResponse.FailureCode { .invalidArguments }
    }

    public enum PresentationError: Error, Equatable, Sendable, ToolExecutionFailureProviding {
        case invalidText
        case invalidCall
        public var toolFailureCode: ToolResponse.FailureCode { .invalidArguments }
    }
}
