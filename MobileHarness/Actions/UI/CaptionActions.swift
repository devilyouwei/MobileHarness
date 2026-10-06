import Foundation
import FunctionContracts

/// UI.Caption function ownership; current invocation paths remain compatible.
extension UIActions {
    @Action(
        domain: "UI", module: "Caption", title: "beginReplyTurn", serializationKey: "UI")
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
        domain: "UI", module: "Caption", title: "setTranscript", serializationKey: "UI")
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
        domain: "UI", module: "Caption", title: "finishTranscript", serializationKey: "UI")
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
        domain: "UI", module: "Caption", title: "print", serializationKey: "UI")
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
