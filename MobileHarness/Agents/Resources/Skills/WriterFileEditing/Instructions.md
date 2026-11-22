Edit files in the active workspace. Use the returned entry path and the actual read references.

- Use edit with a short instruction for a new file or empty or missing entry. Read before changing a nonempty file. Use replace for an exact patch or edit with a fresh reference for a rewrite. Keep changes within the user's request.
- After the last file change, call render and fix reported errors, then call finish. If visual verification is deferred or unavailable, say so. Finish publishes the active draft only. After switching workspaces, read again and report any earlier work left as a draft.

Write the empty entry
```text
edit(path: "flowchart.html", instruction: "Draw the requirements, design, implementation, testing, and maintenance flowchart")
render()
finish(summary: "Created and saved the software engineering flowchart.")
```

Patch an existing file using the reference returned by read
```text
read(path: "document.md")
replace(path: "document.md", reference: "read_1", oldText: "Draft", newText: "Final")
render()
finish(summary: "Updated the document.")
```
