import FunctionContracts

extension ArtifactsActions {
    @Action(
        domain: "Artifacts", module: "Workspace", title: "perform",
        doc:
            "Operate a task-owned artifact workspace. New files and large edits stream separately; replace accepts short exact oldText/newText patches.",
        parameters: [
            .init(
                "command",
                description:
                    "projects/open/delete for Assistant; start/preview/list/read/search/edit/replace/remove/move/removeTree/diff/savepoint/restore/versions/restoreVersion/render/finish for Writer"
            ),
            .init("createProject", required: false, description: "Runtime only: initialize a reserved project ID"),
            .init("projectID", required: false, description: "Existing project ID; absent creates a project"),
            .init("title", required: false, description: "Project title"),
            .init("entry", required: false, description: "Entry file: index.html, document.md or document.txt"),
            .init("path", required: false, description: "Relative file path"),
            .init("offset", required: false, description: "Character offset for paginated read"),
            .init("query", required: false, description: "Literal search text"),
            .init("reference", required: false, description: "Read reference for existing-file edits"),
            .init("start", required: false, description: "Absolute character offset within read range"),
            .init("end", required: false, description: "Exclusive character offset within read range"),
            .init("instruction", required: false, description: "Short editing intent, not source code"),
            .init("line", required: false, description: "One-based starting line for read"),
            .init("limit", required: false, description: "Read lines, 1...100; content capped at 2500 characters"),
            .init(
                "contextReferences", required: false, description: "Comma-separated read IDs for related source context"
            ),
            .init("destination", required: false, description: "Relative destination for file or directory move"),
            .init("revision", required: false, description: "Retained revision ID for restoreVersion"),
            .init("savepoint", required: false, description: "Task-local draft savepoint ID to restore"),
            .init("oldText", required: false, description: "replace only: exact nonempty text within fresh read range"),
            .init(
                "newText", required: false, description: "replace only: exact replacement; empty string deletes match"),
            .init("summary", required: false, description: "Final brief summary"),
        ], timeout: .seconds(60))
    public static func perform(invocation: any FunctionInput, using artifacts: any ArtifactCapability) async throws
        -> String
    {
        try await artifacts.perform(invocation: invocation)
    }
}
