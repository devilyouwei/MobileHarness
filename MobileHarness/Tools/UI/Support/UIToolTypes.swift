extension UITools {
    public enum VoiceState: String, Sendable { case listening, hearing, processing }

    /// Screen-space target: -1 left/up, +1 right/down; zero looks straight ahead.
    public struct Gaze: Sendable, Equatable {
        public let x: Double
        public let y: Double
    }
    public enum GazeError: Error, Equatable, Sendable { case invalidTarget }

    public enum PoseError: Error, Equatable, Sendable { case invalidPayload }

    public enum PresentationError: Error, Equatable, Sendable {
        case invalidText
        case invalidCall
    }
}
