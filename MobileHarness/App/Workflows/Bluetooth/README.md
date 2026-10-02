# AppBluetoothWorkflow

Purpose: own bluetooth application operations in an independent compilation boundary. Design goals: explicit injected effects and unchanged business lifetimes. Direct dependencies: UI, AgentCore, Storage, Actions, ActionRuntime and PlatformKit.

✅ Connection, foreground recovery, Settings/manual admission and presentation remain in one root-owned workflow. This is a source/target move only; existing bounded latest-intent policies, resource fences, fixed plans and feedback completion are unchanged. The full algorithm is documented in the parent workflow README.

```mermaid
flowchart LR
    Root[App composition] -->|Inject operations and services| Workflow[AppBluetoothWorkflow]
    Workflow -->|Actual state and completion| Consumer[UI or caller]
```

❌ Physical safety still requires device-side support and sustained real-device acceptance.
