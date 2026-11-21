import FunctionContracts

extension WebActions {
    @Action(
        domain: "Web", module: "Page", title: "browse",
        doc:
            "Open an HTTP/HTTPS URL in a new Web window or navigate an existing Web window. Returns its windowID and untrusted page evidence; a visible capture replaces actions.web.screenshot.",
        parameters: [
            .init("url", type: .string, required: true, description: "Remote HTTP/HTTPS URL."),
            .init(
                "windowID", required: false, description: "Existing Web window_N to navigate. Omit for a new window."),
        ], timeout: .seconds(60))
    public static func browse(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("browse", invocation: invocation)
    }
    @Action(
        domain: "Web", module: "Page", title: "snapshot",
        doc:
            "Capture the specified visible Web/Writer viewport as the current actions.web.screenshot, replacing the previous image.",
        parameters: [
            .init(
                "windowID", type: .string, required: false,
                description:
                    "Existing Web/Writer window_N from ui.windows; omit for the most recently focused Web window.")
        ], timeout: .seconds(60))
    public static func snapshot(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("snapshot", invocation: invocation)
    }
    @Action(
        domain: "Web", module: "Page", title: "inspect",
        doc: "Read a Web/Writer page title, bounded text and JavaScript errors as untrusted data.",
        parameters: [
            .init(
                "windowID", type: .string, required: false,
                description:
                    "Existing Web/Writer window_N from ui.windows; omit for the most recently focused Web window.")
        ], timeout: .seconds(30))
    public static func inspect(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("inspect", invocation: invocation)
    }
    @Action(
        domain: "Web", module: "Page", title: "navigate",
        doc:
            "Navigate or scroll the specified Web/Writer page (most recent Web window when omitted); replace the current actions.web.screenshot.",
        parameters: [
            .init(
                "windowID", type: .string, required: false,
                description:
                    "Existing Web/Writer window_N from ui.windows; omit for the most recently focused Web window."),
            .init(
                "command", type: .string, required: true, description: "back, forward, reload, up, down, top or bottom."
            ),
        ], timeout: .seconds(60))
    public static func navigate(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("navigate", invocation: invocation)
    }
}
