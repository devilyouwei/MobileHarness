extension UIActions {
    public static func beginReplyTurn(
        invocation: ActionInvocation,
        present: @escaping @Sendable (ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        do { try ActionArguments(invocation.call.parameters).validateAllowedKeys([]) } catch {
            throw PresentationError.invalidCall
        }
        try await present(invocation)
        try Task.checkCancellation()
    }
}
