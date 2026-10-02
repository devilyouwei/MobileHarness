# AppSettingsWorkflow

Purpose: own settings application operations in an independent compilation boundary. Design goals: explicit injected effects and unchanged business lifetimes. Direct dependencies: UI and Storage.

✅ Settings restore/discovery/save, provider preparation and application are injected; the original begin/end barrier, credential persistence, migration and rollback order remain unchanged. One mutation rejects overlap and concurrent restore coalesces. No operation queue is added.

```mermaid
flowchart LR
    Root[App composition] -->|Inject operations and services| Workflow[AppSettingsWorkflow]
    Workflow -->|Actual state and completion| Consumer[UI or caller]
```

❌ Provider selection belongs to App/Adapters; real Keychain/provider acceptance remains separate.

✅ An internal SettingsPersistence seam retains the same production CloudSettingsStore; isolated transaction tests exercise validation-before-persistence and rollback-before-barrier-release without Keychain or network access.
