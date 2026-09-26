import ActionRuntime

extension UIActions {
    public enum ExpressionError: Error, Equatable, Sendable {
        case invalidEmotion
    }

    /// Presents a finite UI expression; never substitutes an unknown emotion.
    public static func express(
        invocation: ActionInvocation,
        present: @escaping @Sendable (String, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let emoji: String
        switch invocation.call.parameters["emotion"] {
        case "clear": emoji = ""
        case "smile": emoji = "🙂"
        case "happy": emoji = "😊"
        case "laugh": emoji = "😄"
        case "thinking": emoji = "🤔"
        case "surprised": emoji = "😮"
        case "sad": emoji = "😔"
        case "love": emoji = "🥰"
        default: throw ExpressionError.invalidEmotion
        }
        try await present(emoji, invocation)
        try Task.checkCancellation()
    }
}
