import AgentCore
import Foundation

extension UITools {
    public static func print(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (String, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let text: String
        do {
            let arguments = CallArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["text"])
            text = try arguments.requiredString("text", maximumUTF8Bytes: 2000, allowBlank: false)
        } catch { throw PresentationError.invalidText }
        try await present(text, invocation)
        try Task.checkCancellation()
    }
}
