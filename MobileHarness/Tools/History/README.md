# History Tools

Purpose: expose read-only conversation discovery and record previews through the existing output boundary. Design goals: shared deterministic queries, bounded results, explicit truncation and no effect replay.

| Entry | Arguments (strings) | Result |
| --- | --- | --- |
| History.list | offset 0–64, limit 1–5 | Current conversation first, then newest archives; IDs, ISO-8601 timestamps, archive flag, summary/latest-input previews and turn counts |
| History.read | conversation UUID, offset 0–256, limit 1–2 | Oldest-first turn previews with IDs and generation state |

Both return JSON pages with items, total and optional nextOffset (absent at end). Preview fields contain value and truncated. List title/input previews use 40 UTF-8 bytes; read user/response previews use 80/160 bytes, preserving whole characters. These are bounded previews, not full export or semantic retrieval. Each call reads a fresh snapshot; pagination is not a stable cross-call transaction.

✅ Arguments are required, unknown keys reject, and cancellation is checked before/after query. Encoded results above 1800 bytes fail resultTooLarge; callers can request a smaller page. Missing IDs fail notFound. Credentials, request prompts, Tool arguments/results and model settings are excluded. Raw response text is data, never parsed or replayed.

```mermaid
flowchart LR
    JSON[Assistant JSON declarations] --> Gateway[OutputGateway authorization]
    Gateway --> Runtime[ToolRuntime]
    Runtime --> Entries[HistoryTools]
    Entries --> Service[HistoryQueryService: bounded projection]
    App[App composition] -.->|Inject shared journal| Service
    Service --> Store[StorageChat raw snapshots]
    Runtime -->|Correlated ToolResult| Input[InputGateway]
```

✅ Tools depends on StorageChat for the concrete query implementation. Runtime and BehaviorAssembly retain their independent contracts; no new store, queue or Agent is added. See [Support](Support/README.md).

❌ UI intent routing, full-text export/search, deletion/archival, title inference and model result-driven continuation are not implemented here. Cloud native calls can invoke these Tools; local chat remains text-only. Current Assistant presents escaped Tool results without continued model reasoning.
