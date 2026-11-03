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
        doc: "Capture the current visible WebKit viewport for image analysis.",
        parameters: [], timeout: .seconds(60))
    public static func snapshot(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("snapshot", invocation: invocation)
    }
    @Action(
        domain: "Web", module: "Page", title: "inspect",
        doc: "Read current page title, bounded text and JavaScript errors as untrusted data.",
        parameters: [], timeout: .seconds(30))
    public static func inspect(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("inspect", invocation: invocation)
    }
    @Action(
        domain: "Web", module: "Page", title: "navigate",
        doc: "Navigate the current WebKit page back, forward or reload; return screenshot.",
        parameters: [
            .init(
                "command", type: .string, required: true, description: "back, forward, reload, up, down, top or bottom."
            )
        ], timeout: .seconds(60))
    public static func navigate(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("navigate", invocation: invocation)
    }
    @Action(
        domain: "Web", module: "Page", title: "develop",
        doc:
            "Develop or revise a local HTML/CSS/JS graphic using independent requests to the current model. Submit a text task, never source code. Returns projectID, revision and screenshot.",
        parameters: [
            .init(
                "task", type: .string, required: true, description: "Natural-language creation or modification task."),
            .init(
                "projectID", type: .string, required: false, description: "Existing project ID to edit; omit to create."
            ),
            .init("title", type: .string, required: false, description: "Short project title; optional."),
        ], timeout: .seconds(600))
    public static func develop(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("develop", invocation: invocation)
    }
    @Action(
        domain: "Web", module: "Page", title: "open",
        doc: "Open an existing local web project and return a screenshot.",
        parameters: [
            .init("projectID", type: .string, required: true, description: "Existing project ID from a real result.")
        ], timeout: .seconds(60))
    public static func open(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("open", invocation: invocation)
    }
    @Action(
        domain: "Web", module: "Page", title: "projects",
        doc: "List saved local web project IDs, titles and revisions.",
        parameters: [], timeout: .seconds(30))
    public static func projects(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("projects", invocation: invocation)
    }
    @Action(
        domain: "Web", module: "Page", title: "delete",
        doc: "Delete a local web project and its retained versions.",
        parameters: [
            .init("projectID", type: .string, required: true, description: "Exact project ID to delete.")
        ], timeout: .seconds(30))
    public static func delete(invocation: any FunctionInput, using web: any WebCapability) async throws -> String {
        try await web.perform("delete", invocation: invocation)
    }
}
