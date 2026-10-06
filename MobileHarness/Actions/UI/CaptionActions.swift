import ActionRuntime
import Foundation

/// UI.Caption function ownership; current invocation paths remain compatible.
extension UIActions {
    @Tool(path: "UI.Caption.beginReplyTurn", title: "beginReplyTurn")
    public static func beginReplyTurn(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        do { try ToolArguments(invocation.call.arguments).validateAllowedKeys([]) } catch {
            throw PresentationError.invalidCall
        }
        try await present(invocation)
        try Task.checkCancellation()
    }

    /// Replace the recognition caption; unlike UI.print, empty text is an explicit clear.
    @Tool(path: "UI.Caption.setTranscript", title: "setTranscript")
    public static func setTranscript(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (String, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let text: String
        do {
            let arguments = ToolArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["text"])
            text = try arguments.requiredString("text", maximumUTF8Bytes: 4096, allowBlank: true)
        } catch { throw PresentationError.invalidText }
        try await present(text, invocation)
        try Task.checkCancellation()
    }

    @Tool(path: "UI.Caption.finishTranscript", title: "finishTranscript")
    public static func finishTranscript(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        do { try ToolArguments(invocation.call.arguments).validateAllowedKeys([]) } catch {
            throw PresentationError.invalidCall
        }
        try await present(invocation)
        try Task.checkCancellation()
    }

    @Tool(path: "UI.Caption.print", title: "print")
    public static func print(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (String, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let text: String
        do {
            let arguments = ToolArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["text"])
            text = try arguments.requiredString("text", maximumUTF8Bytes: 2000, allowBlank: false)
        } catch { throw PresentationError.invalidText }
        try await present(text, invocation)
        try Task.checkCancellation()
    }
}
