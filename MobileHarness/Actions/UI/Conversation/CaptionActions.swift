import Foundation
import FunctionContracts

/// UI.Caption function ownership; current invocation paths remain compatible.
extension UIActions {
    @Action(
        domain: "UI", module: "Caption", title: "beginReplyTurn", timeout: .seconds(5))
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

    /// Clear only the caller's reply caption at an accepted new user-input boundary.
    @Action(
        domain: "UI", module: "Caption", title: "clearReply",
        parameters: [
            .init("replyInputID", type: .string, required: false, description: "Runtime-owned reply request to retire.")
        ], timeout: .seconds(5))
    public static func clearReply(
        invocation: any FunctionInput,
        using present: @escaping @Sendable (any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        do {
            let args = ActionArguments(invocation.call.parameters)
            try args.validateAllowedKeys(["replyInputID"])
            if invocation.call.parameters["replyInputID"] != nil {
                _ = try args.requiredString("replyInputID", maximumUTF8Bytes: 256)
            }
        } catch { throw PresentationError.invalidCall }
        try await present(invocation)
        try Task.checkCancellation()
    }

    /// Replace the recognition caption; unlike UI.print, empty text is an explicit clear.
    @Action(
        domain: "UI", module: "Caption", title: "setTranscript", timeout: .seconds(5))
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
        domain: "UI", module: "Caption", title: "finishTranscript", timeout: .seconds(5))
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
        domain: "UI", module: "Caption", title: "print", timeout: .seconds(5))
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
