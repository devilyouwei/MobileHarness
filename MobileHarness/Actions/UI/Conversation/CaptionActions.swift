import Foundation
import FunctionContracts

/// UI.Caption function ownership; current invocation paths remain compatible.
extension UIActions {
    @Action(
        domain: "UI", module: "Caption", title: "beginReplyTurn",
        doc: "Begin a reply caption turn so later reply text is shown in its own caption slot.", timeout: .seconds(5))
    public static func beginReplyTurn(
        invocation: any FunctionInput,
        using present: @escaping @Sendable (any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        do { try ActionArguments(invocation.call.parameters).validateAllowedKeys([]) } catch {
            throw PresentationError.invalidCall
        }
        try await present(invocation)
        try Task.checkCancellation()
    }

    /// Replace the recognition caption; unlike UI.print, empty text is an explicit clear.
    @Action(
        domain: "UI", module: "Caption", title: "setTranscript",
        doc: "Replace the recognition caption with the given text; empty text clears it.", timeout: .seconds(5))
    public static func setTranscript(
        invocation: any FunctionInput,
        using present: @escaping @Sendable (String, any FunctionInput) async throws -> Void
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

    @Action(
        domain: "UI", module: "Caption", title: "finishTranscript",
        doc: "Finalize the recognition caption currently shown.", timeout: .seconds(5))
    public static func finishTranscript(
        invocation: any FunctionInput,
        using present: @escaping @Sendable (any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        do { try ActionArguments(invocation.call.parameters).validateAllowedKeys([]) } catch {
            throw PresentationError.invalidCall
        }
        try await present(invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "UI", module: "Caption", title: "print", doc: "Show reply text in the current reply caption.",
        timeout: .seconds(5))
    public static func print(
        invocation: any FunctionInput,
        using present: @escaping @Sendable (String, any FunctionInput) async throws -> Void
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
