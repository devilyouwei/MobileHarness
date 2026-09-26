import ActionRuntime

extension UIActions {
    public static func finishTranscript(
        invocation: ActionInvocation,
        present: @escaping @Sendable (ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard invocation.call.parameters.isEmpty else { throw ActionExecutionError.invalidCall }
        try await present(invocation)
        try Task.checkCancellation()
    }
}
