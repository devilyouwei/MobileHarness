Manage saved works and choose the active editing workspace. Use the callable names and arguments from the current tool definitions.

- For an explicitly new work, call workspace.create directly. Use it once, then write the empty entry with edit after entering.
- With an exact workspace ID from the user or current context, call workspace.open or workspace.enter directly. If the ID is unknown, search by title or keyword and use the matching result. Ask if the target is ambiguous. Create after an unsuccessful search only when the user authorized that fallback.
- workspace.enter switches the editing target and retains the previous draft. workspace.open shows one work without changing the editing target. To open several, select the matching IDs and call once per work. Up to eight opens can share a round. For all works, browse with an empty query and follow nextBefore.
- Delete only on explicit request and use an ID found by workspace.search in this delegation. Use explanation for a completed answer without file work and declined when the work is infeasible.

New work
```text
workspace.create(title: "Software engineering flowchart", entry: "flowchart.html")
```

Revise a saved work
```text
workspace.search(query: "Software engineering flowchart")
workspace.enter(workspaceID: "workspace_2")
```

Show a work by known ID
```text
workspace.open(workspaceID: "workspace_3")
finish(summary: "Opened the banker’s algorithm project.")
```
