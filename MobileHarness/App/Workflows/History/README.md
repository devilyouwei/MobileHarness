# AppHistoryWorkflow

Purpose: own history application operations in an independent compilation boundary. Design goals: explicit injected effects and unchanged business lifetimes. Direct dependencies: UI and StorageChat.

✅ One root-owned history operation slot persists until cancellation cleanup finishes. Archive/delete/title metadata policy is unchanged. Title generation and dry-run output preview are injected; Agent parsers and model implementations are not imported.

```mermaid
flowchart LR
    Root[App composition] -->|Inject operations and services| Workflow[AppHistoryWorkflow]
    Workflow -->|Actual state and completion| Consumer[UI or caller]
```

❌ Real title/model acceptance remains separate; no background retry or durable execution is added.
