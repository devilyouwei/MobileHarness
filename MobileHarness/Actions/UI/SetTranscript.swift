extension UIActions {
    /// Replace the recognition caption; unlike UI.print, empty text is an explicit clear.
    public static func setTranscript(
        invocation: ActionInvocation,
        present: @escaping @Sendable (String, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let text: String
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["text"])
            text = try arguments.requiredString("text", maximumUTF8Bytes: 4096, allowBlank: true)
        } catch { throw PresentationError.invalidText }
        try await present(text, invocation)
        try Task.checkCancellation()
    }
}
