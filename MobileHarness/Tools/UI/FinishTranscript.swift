import AgentCore

extension UITools {
    public static func finishTranscript(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        do { try CallArguments(invocation.call.arguments).validateAllowedKeys([]) } catch {
            throw PresentationError.invalidCall
        }
        try await present(invocation)
        try Task.checkCancellation()
    }
}
