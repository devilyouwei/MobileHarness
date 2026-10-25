extension UIActions {
    /// Semantic identifiers only; presentation owns the procedural eye geometry.
    public enum Emotion: String, CaseIterable, Sendable {
        case clear, closed, smile, happy, laugh, thinking, surprised, sad, love, angry, scared, playful
    }

    /// Retains both failures when best-effort override cleanup also fails.
    public struct ExpressionCleanupFailure: Error, Sendable {
        public let primary: any Error
        public let cleanup: any Error
        public init(primary: any Error, cleanup: any Error) {
            self.primary = primary
            self.cleanup = cleanup
        }
    }

    public enum ExpressionError: Error, Equatable, Sendable {
        case invalidEmotion, busy, rendererUnavailable
    }
}
