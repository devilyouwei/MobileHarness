import FunctionContracts

extension ArtifactsActions {
    static let workspaceDeclarations: [ActionDeclaration] = [
        workspace(
            "searchWorkspaces", "Find saved works. Use an empty query to browse the catalog.",
            [
                .init("query", description: "Literal title, description or task ID."),
                .init("before", required: false, description: "Cursor returned as nextBefore."),
            ]),
        workspace(
            "open", "Open one saved work without entering its editing workspace. Several open calls can share a round.",
            [taskID]),
        workspace("delete", "Delete one saved work on explicit user request.", [taskID]),
        workspace("list", "List files in the active workspace.", [prefix]),
        workspace(
            "read", "Read a file range and return a fresh edit reference.",
            [
                path, offset, limit, .init("line", required: false, description: "One-based decimal line number."),
            ]),
        workspace(
            "search", "Find literal text within active workspace files.",
            [
                .init("query", description: "Nonempty literal text."), prefix, offset, limit,
            ]),
        workspace(
            "edit",
            "Generate a new file or rewrite the range of a fresh read. Pass an instruction; source streams separately.",
            [
                path, .init("instruction", description: "Brief change request for the content writer."),
                .init("reference", required: false, description: "Fresh read reference. Omit for a new file."),
                .init(
                    "start", required: false,
                    description: "Absolute Unicode character offset as a decimal string within the read range."),
                .init(
                    "end", required: false,
                    description:
                        "Exclusive absolute Unicode character offset as a decimal string within the read range."),
                .init(
                    "contextReferences", required: false,
                    description: "Comma-separated fresh read references for related files."),
                .init("title", required: false, description: "Optional artifact title."),
            ]),
        workspace(
            "replace", "Apply an exact patch within a fresh read range. The old text must match once.",
            [
                path, reference, .init("oldText", description: "Exact nonempty old text."),
                .init("newText", description: "Exact replacement. Empty deletes the match."),
            ]),
        workspace("remove", "Delete a file after reading it. The entry file is protected.", [path, reference]),
        workspace(
            "move", "Move a file or directory after reading every affected file.",
            [
                path, .init("destination", description: "New project-relative path."),
            ]),
        workspace(
            "removeTree", "Delete a directory after reading every affected file. The entry file is protected.", [path]),
        workspace("diff", "Compare the current draft against a savepoint.", [savepoint, prefix, offset, limit]),
        workspace("savepoint", "Capture an in-memory editing checkpoint."),
        workspace("restore", "Restore a checkpoint in the current editing session.", [savepoint]),
        workspace("rename", "Rename the current work.", [.init("title", description: "Nonempty artifact title.")]),
        workspace("render", "Render the latest draft and return diagnostics and visible-page evidence."),
        workspace("start", "Prepare a Writer editing session.", editingSession),
        workspace("resume", "Resume a Writer editing session.", editingSession),
        workspace("describe", "Update the current work's window subtitle.", [subtitle]),
        workspace("preview", "Refresh the current work's preview."),
        workspace(
            "publish", "Publish the latest validated Writer draft.",
            [.init("summary", description: "Final brief summary.")]),
    ]

    private static let taskID = ActionParameter("taskID", description: "Saved task_N returned by searchWorkspaces.")
    private static let path = ActionParameter("path", description: "Project-relative path.")
    private static let prefix = ActionParameter(
        "path", required: false, description: "Project-relative path or directory prefix.")
    private static let offset = ActionParameter(
        "offset", required: false, description: "Decimal offset or nextOffset from the previous result.")
    private static let limit = ActionParameter("limit", required: false, description: "Positive decimal result limit.")
    private static let reference = ActionParameter("reference", description: "Fresh read_N reference for this file.")
    private static let savepoint = ActionParameter("savepoint", description: "Checkpoint ID returned by savepoint.")
    private static let subtitle = ActionParameter(
        "subtitle", required: false, description: "Current goal or actual operation.")
    private static let editingSession: [ActionParameter] = [
        .init("workspaceID", description: "Host-bound registered workspace identity."),
        .init("createWorkspace", required: false, description: "Initialize an allocated workspace."),
        .init("title", required: false, description: "Artifact title."),
        .init("entry", required: false, description: "Project entry file."),
        subtitle,
    ]

    private static func workspace(_ name: String, _ doc: String, _ parameters: [ActionParameter] = [])
        -> ActionDeclaration
    {
        .init(path: .init(domain: "Artifacts", module: "Workspace", function: name), doc: doc, parameters: parameters)
    }
}
