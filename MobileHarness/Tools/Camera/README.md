# Camera Tools

Purpose: expose explicit camera/vision controls through OutputGateway. Design goals: domain-owned entries, typed host injection, no direct device ownership and honest completion.

| Entry | Contract |
| --- | --- |
| Camera.open | No arguments; idempotently enable capture and vision intent |
| Camera.close | No arguments; idempotently disable capture and vision |
| Camera.flip | No arguments; switch front/rear lens; disabled camera fails |

✅ CameraTools.swift owns @Tool entries; Support/CameraToolModule.swift owns definitions, capability and errors. All entries check cancellation and reject unknown arguments before effects. Completion-only success produces no ToolResult or Action history. Host errors propagate.

```mermaid
flowchart LR
    Agent[Assistant JSON Tool declaration] --> Gateway[OutputGateway permissions]
    Gateway --> Runtime[ToolRuntime]
    Runtime --> Entry[CameraTools]
    Entry --> Adapter[App session validation]
    Adapter --> Owner[CameraCoordinator]
    Owner --> Permission[Permission and foreground check]
    Permission --> Lease[Existing camera capture lease]
    Lease --> Capture[Native camera and vision lifecycle]
```

✅ App validates the active Assistant voice session and foreground. The coordinator rejects overlapping Tool operations with busy; UI/scene changes can supersede an admitted operation, which then fails cancellation. There is no Tool queue. Open/flip wait for native capture reconciliation; close waits for capture release and vision cleanup. Open does not promise pose-model readiness. Existing bounded frame streams and permission validation remain.

✅ Tool definitions claim no camera.capture lock: they request the single App camera owner to change intent; that owner alone acquires/renews/releases the lease. Taking another lease at Gateway would conflict with the active capture owner. Tools imports only Foundation/ToolRuntime and gains no PlatformKit dependency.

❌ Native model Tool event transport, background capture, forced interruption of native calls and physical-device acceptance are not added. Cancelling after an intent is accepted does not roll back that intent; scene shutdown still owns cleanup.
