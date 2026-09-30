/// Stateless namespace for scheduled presentation actions.
public enum UIActions {
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
