import Foundation

extension UIActions {
    public static func print(
        invocation: ActionInvocation,
        using present: @escaping @Sendable (String, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let text: String
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["text"])
            text = try arguments.requiredString("text", maximumUTF8Bytes: 2000, allowBlank: false)
        } catch { throw PresentationError.invalidText }
        try await present(text, invocation)
        try Task.checkCancellation()
    }
}
