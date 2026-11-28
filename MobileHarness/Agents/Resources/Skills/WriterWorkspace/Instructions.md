Manage saved works and choose the active editing workspace. Use the callable names and arguments from the current tool definitions.

- For an explicitly new work, call workspace.create directly. Call it alone. It enters the new workspace; write the empty entry with edit in a later round.
- From the library, call workspace.enter alone to edit an existing work. Once in its editing workspace, use the edit tools directly. workspace.open is read-only viewing and cannot edit. Never finish with declined merely because the editing tools are not yet listed; enter the workspace instead.
- With an exact workspace ID from the user or current context, call workspace.open for viewing or workspace.enter for editing directly. If the ID is unknown, search by title or keyword and use the matching result. Ask if the target is ambiguous. Create after an unsuccessful search only when the user authorized that fallback.
- workspace.enter switches the editing target and retains the previous draft. workspace.open shows one work without changing the editing target. To open several, select the matching IDs and call once per work. Up to eight opens can share a round. For all works, browse with an empty query and pass its returned nextBefore as before on the next search.
- Delete only on explicit request and use an ID found by workspace.search in this delegation. Use explanation for a completed answer without file work and declined when the work is infeasible.
- When the user asks to stop, call finish alone with outcome="cancelled" to preserve the draft.

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
