import FunctionContracts

extension WebActions {
    @Action(
        domain: "Web", module: "Page", title: "browse",
        doc:
            "Browse an HTTP/HTTPS URL in the WebKit window; return visible screenshot mediaID and untrusted page text.",
        parameters: [
            .init("url", type: .string, required: true, description: "Remote HTTP/HTTPS URL.")
        ], timeout: .seconds(60))
    public static func browse(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("browse", invocation: invocation)
    }
    @Action(
        domain: "Web", module: "Page", title: "snapshot",
        doc: "Capture the specified visible Web/Writer window viewport for image analysis.",
        parameters: [
            .init(
                "windowID", type: .string, required: false,
                description: "Existing Web/Writer window UUID from ui.windows; omit only for the root browser page.")
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
                description: "Existing Web/Writer window UUID from ui.windows; omit only for the root browser page.")
        ], timeout: .seconds(30))
    public static func inspect(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("inspect", invocation: invocation)
    }
    @Action(
        domain: "Web", module: "Page", title: "navigate",
        doc: "Navigate or scroll the specified Web/Writer page (root browser when omitted); return screenshot.",
        parameters: [
            .init(
                "windowID", type: .string, required: false,
                description: "Existing Web/Writer window UUID from ui.windows; omit for root browser."),
            .init(
                "command", type: .string, required: true, description: "back, forward, reload, up, down, top or bottom."
            ),
        ], timeout: .seconds(60))
    public static func navigate(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("navigate", invocation: invocation)
    }
}
