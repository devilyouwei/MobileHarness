import ActionRuntime
import Foundation

public enum UIActions {
    public static func print(
        invocation: ActionInvocation,
        present: @escaping @Sendable (String, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let text = invocation.call.parameters["text"], text.utf8.count <= 2_000,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ActionExecutionError.invalidText }
        try await present(text, invocation)
        try Task.checkCancellation()
    }
}
