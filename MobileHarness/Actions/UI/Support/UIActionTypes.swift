import ActionRuntime

extension UIActions {
    /// Semantic identifiers only; presentation owns the procedural eye geometry.
    public enum Emotion: String, CaseIterable, Sendable {
        case clear, smile, happy, laugh, thinking, surprised, sad, love, angry, scared, playful
    }

    public enum ExpressionError: Error, Equatable, Sendable {
        case invalidEmotion
    }
}
