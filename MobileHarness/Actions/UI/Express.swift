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
        using present: @escaping @Sendable (Emotion, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let emotion: Emotion
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["emotion"])
            emotion = try arguments.requiredEnum("emotion", as: Emotion.self)
        } catch { throw ExpressionError.invalidEmotion }
        try await present(emotion, invocation)
        try Task.checkCancellation()
    }
}
