extension UIActions {
    /// Replace the recognition caption; unlike UI.print, empty text is an explicit clear.
    public static func setTranscript(
        invocation: ActionInvocation,
        present: @escaping @Sendable (String, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let text = invocation.call.parameters["text"], text.utf8.count <= 4096 else {
            throw ActionExecutionError.invalidText
        }
        try await present(text, invocation)
        try Task.checkCancellation()
    }
}
