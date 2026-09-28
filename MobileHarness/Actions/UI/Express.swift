extension UIActions {
    /// Semantic identifiers only; presentation owns the procedural eye geometry.
    public enum Emotion: String, CaseIterable, Sendable {
        case clear, smile, happy, laugh, thinking, surprised, sad, love, angry, scared, playful
    }

    public enum ExpressionError: Error, Equatable, Sendable {
        case invalidEmotion
    }

    public static func express(
        invocation: ActionInvocation,
        present: @escaping @Sendable (Emotion, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let value = invocation.call.parameters["emotion"], let emotion = Emotion(rawValue: value) else {
            throw ExpressionError.invalidEmotion
        }
        try await present(emotion, invocation)
        try Task.checkCancellation()
    }
}
