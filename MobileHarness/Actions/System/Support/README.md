# System Action Support

Purpose: assemble the system function catalog. Design goals: explicit factories, no registration policy and no state or queue.

✅ SystemModule.swift exposes one ActionFunction whose canonical handler calls SystemActions.runtimeInfo and returns ActionCompletion.value. Host composition separately creates ActionBinding; the catalog imports FunctionContracts only and grants no Agent permission.

```mermaid
flowchart LR
    Catalog[CapabilityModules] --> Module[SystemModule]
    Module --> Function[ActionFunction / canonical handler]
    Function --> Entry[SystemActions.runtimeInfo]
```

❌ No live health service, discovery or additional system capability is implemented. The current function returns fixed text.

✅ ADR0161: standard callable inputs use FunctionInput/FunctionContracts; common execution and call protocols belong to independent Gateway targets. This directory retains its existing ownership, resource/permission and lifecycle boundaries. ❌ Remaining feature Signal/continuation and physical acceptance are separate work.
