import FunctionContracts

extension ArtifactsActions {
    static let workspaceDeclarations: [ActionDeclaration] = [
        workspace(
            "searchWorkspaces", "Find saved works. Use an empty query to browse the catalog.",
            [
                .init(
                    "query",
                    description: "Title or description keyword, or exact workspace_N. Use an empty string to browse."),
                .init(
                    "before", required: false,
                    description: "nextBefore from the previous page of the same query. Omit for the first page."),
            ]),
        workspace(
            "open", "Open one saved work without entering its editing workspace. Several open calls can share a round.",
            [
                .init(
                    "workspaceID",
                    description: "Exact workspace_N known from the user, current context, or workspace.search.")
            ]),
        workspace(
            "delete", "Delete one saved work on explicit user request.",
            [.init("workspaceID", description: "Exact workspace_N from this delegation's workspace.search results.")]),
        workspace("list", "List files in the active workspace.", [prefix]),
        workspace(
            "read", "Read a file range and return a fresh edit reference.",
            [
                path,
                .init(
                    "offset", required: false,
                    description: "Zero-based character offset. Omit to start at zero. Ignored when line is supplied."),
                .init(
                    "limit", required: false,
                    description:
                        "Positive decimal count of characters, or lines when line is supplied. Defaults to 2500 characters or 60 lines."
                ),
                .init(
                    "line", required: false,
                    description: "One-based decimal starting line. Omit to read by character offset."),
            ]),
        workspace(
            "search",
            "Find literal text in active workspace files. Returns up to 16 matching lines per page and nextOffset when more remain.",
            [
                .init("query", description: "Nonempty case-sensitive literal text."), prefix, offset("matches"),
            ]),
        workspace(
            "edit",
            "Write a new file or an empty entry, or rewrite the range of a fresh read. Pass an instruction; source streams separately.",
            [
                path,
                .init(
                    "instruction",
                    description:
                        "Nonempty instruction describing what to write or change. The content writer generates the source."
                ),
                .init(
                    "reference", required: false,
                    description: "Fresh read reference. Omit for a new file or empty entry."),
                .init(
                    "start", required: false,
                    description:
                        "Absolute Unicode character offset as a decimal string within the read range. Defaults to the start of that range."
                ),
                .init(
                    "end", required: false,
                    description:
                        "Exclusive absolute Unicode character offset as a decimal string within the read range. Defaults to the end of that range."
                ),
                .init(
                    "contextReferences", required: false,
                    description:
                        "Comma-separated fresh read references for related files. Omit when no extra file context is needed."
                ),
                .init(
                    "title", required: false,
                    description: "New display title for the work. Omit to keep the current title."),
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
                treePath,
                .init("destination", description: "Unused workspace-relative destination file or directory path."),
            ]),
        workspace(
            "removeTree", "Delete a directory after reading every affected file. The entry file is protected.",
            [treePath]),
        workspace(
            "diff",
            "Compare the current draft with a savepoint. Returns excerpts for up to two changed files per page.",
            [
                savepoint,
                .init("path", required: false, description: "Exact relative file path. Omit for all changed files."),
                offset("changed files"),
            ]),
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

    private static let path = ActionParameter(
        "path", description: "Workspace-relative file path, such as docs/flowchart.md.")
    private static let treePath = ActionParameter(
        "path", description: "Exact workspace-relative file or directory path.")
    private static let prefix = ActionParameter(
        "path", required: false, description: "Relative file or directory prefix. Omit to include all paths.")
    private static func offset(_ unit: String) -> ActionParameter {
        .init(
            "offset", required: false,
            description: "Zero-based decimal offset in \(unit). Use nextOffset to continue or omit to start at zero.")
    }
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
