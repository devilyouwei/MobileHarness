import FunctionContracts

extension UIActions {
    @Action(
        domain: "UI", module: "Notice", title: "Show text notice",
        doc:
            "Commit a transient centered text notice. Does not create an error record or task. Actual runtime errors have priority; host rejects stale scopes.",
        parameters: [
            .init("text", type: .string, required: true, description: "Nonblank notice, at most 1024 UTF-8 bytes."),
            .init(
                "tone", type: .string, required: false, description: "Default warning.",
                values: ["info", "warning", "error"]),
            .init(
                "durationMS", type: .integer, required: false, description: "Auto-dismiss delay; default 8000.",
                constraints: "500 through 30000 milliseconds."),
        ], completion: "Presentation state committed; root owns expiry.", timeout: .seconds(5))
    public static func showNotice(
        invocation: any FunctionInput,
        using present: @escaping @Sendable (NoticeRequest, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["text", "tone", "durationMS"])
        let request = try NoticeRequest(
            text: args.requiredString("text", maximumUTF8Bytes: 1024),
            tone: invocation.call.parameters["tone"] == nil ? .warning : args.requiredEnum("tone", as: NoticeTone.self),
            durationMS: invocation.call.parameters["durationMS"] == nil
                ? 8000 : args.requiredInt("durationMS", range: 500...30000))
        try await present(request, invocation)
    }

    @Action(
        domain: "UI", module: "Notice", title: "Clear text notice",
        doc: "Clear only this producer/session's transient notice; never clears factual runtime errors or a task goal.",
        completion: "Matching notice removed and expiry cancelled.", timeout: .seconds(5))
    public static func dismissNotice(
        invocation: any FunctionInput,
        using dismiss: @escaping @Sendable (any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await dismiss(invocation)
    }
}
