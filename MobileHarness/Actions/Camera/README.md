# Camera Actions

Purpose: expose explicit camera/vision controls through OutputGateway. Design goals: domain-owned entries, typed host injection, no direct device ownership and honest completion.

| Entry | Contract |
| --- | --- |
| Camera.Capture.open | No arguments; idempotently enable capture and vision intent |
| Camera.Capture.close | No arguments; idempotently disable capture and vision |
| Camera.Capture.flip | Required facing=front/back; select target lens, healthy same-target request is idempotent; disabled camera fails |

✅ CaptureActions.swift owns @Action entries; Support/CameraModule.swift owns definitions, capability and errors. All entries check cancellation and reject unknown arguments before effects. Host registration exposes the four controls as native observation calls; takePhoto is dual-protocol with observation and Photographer text exposure. Host errors propagate.

```mermaid
flowchart LR
    Agent[Photographer JSON Tool declaration] --> Gateway[OutputGateway permissions]
    Gateway --> Runtime[FunctionContracts]
    Runtime --> Entry[CameraActions]
    Entry --> Adapter[App session validation]
    Adapter --> Owner[CameraCoordinator]
    Owner --> Permission[Permission and foreground check]
    Permission --> Lease[Existing camera capture lease]
    Lease --> Capture[Native camera and vision lifecycle]
```

✅ App validates the actual Photographer and active root/task scope plus foreground. The coordinator rejects overlapping Tool operations with busy; UI/scene changes can supersede an admitted operation, which then fails cancellation. There is no Tool queue. Open/flip wait for native capture reconciliation; close waits for capture release and vision cleanup. Open does not promise pose-model readiness. Existing bounded frame streams and permission validation remain.

✅ Camera function constraints claim no camera.capture lock: they request the single App camera owner to change intent; that owner alone acquires/renews/releases the lease. Taking another lease at Gateway would conflict with the active capture owner. Camera Actions imports only Foundation/FunctionContracts and gains no PlatformKit dependency.

❌ Background capture, forced termination of native callbacks and physical-device acceptance are not provided. Cancelling after an intent is accepted does not roll back that intent; scene shutdown still owns cleanup.

✅ ADR0151: this domain is compiled once in Actions; both ActionCall and ToolCall entries use FunctionContracts contracts. Host injection and permission/feedback behavior are unchanged.
✅ Shared execution from ADR0157 is retained; ADR0160 separates callable functions from host bindings.

✅ ADR0152: functions are classified by domain before protocol unification. Canonical namespaces use `<Domain>Actions`; production uses one pure `<Domain>Module`; host registration creates Action/Tool projections. Legacy aliases are retired; isolated registration views retain one canonical catalog.
✅ Unified definitions and compatibility retirement are implemented in ADR0157.

## Cohesive module files — ADR0154

Purpose: implement directory/module-file/function ownership while preserving current protocol APIs. The domain Actions enum remains a used namespace facade; callable bodies belong exclusively to the files below. Support owns one domain catalog, values and host capabilities.

- [CaptureActions.swift](CaptureActions.swift)

✅ Implementations are split without forwarding or duplicated metadata/handlers. Generated factories and existing call paths, permissions, resources and scheduling are unchanged.
✅ Three-field addresses, Agent v6 configuration and shared definitions/results are implemented in ADR0156/0157.

✅ ADR0159 — Unified invocation: all business functions, injected capabilities and registered handlers receive FunctionInput with ActionExecutionContext. Native request/result normalization stays in Runtime/Gateway; no protocol-specific implementation signature remains.

✅ ADR0160: this domain exposes ActionFunction values with canonical invocation and intrinsic constraints. Protocol availability, native scheduling and feedback belong to host-created ActionBinding; domain code consumes no Tool wire/error contracts. ❌ New feature/physical acceptance remains separate.

✅ ADR0161: standard callable inputs use FunctionInput/FunctionContracts; common execution and call protocols belong to independent Gateway targets. This directory retains its existing ownership, resource/permission and lifecycle boundaries. ❌ Remaining feature Signal/continuation and physical acceptance are separate work.


## Camera command entry

✅ Implemented: CameraInteractionWorkflow emits typed open/close/flip/retry intents through Assistant task delegation to Photographer and existing Camera functions. Root presentation accepts the real Photographer in the stable root session or validated active task scope. Native capture, permission, lifecycle fences and joined cleanup remain CameraCoordinator responsibilities. Retry uses a canonical callable and the native explicit settings/permission request. UI receives controls and passive camera state, not the native coordinator. One command slot rejects overlap, no replay.

✅ ADR0181 host migration: function paths and native lifecycle remain unchanged; flip now requires explicit facing. The injected camera endpoint applies admitted Photographer effects directly; Assistant delegates through task communication. Functions remain unaware of Agent identity or delegation protocol.

✅ Interaction refinement: CaptureActions.flip validates required facing (front/back) and calls the typed target-selection endpoint; selecting the current lens is idempotent when capture is healthy.

## Assistant photo observation — ADR0184

✅ Implemented: CaptureActions.takePhoto validates no arguments and returns photoID/width/height/MIME from CameraControlCapability.takePhoto. Existing control endpoints stay unchanged. Photo observation reading validates originating source/session/input.

❌ Real camera/shutter/animation and configured-model vision acceptance remain pending; video recording remains outside this iteration; system Photos export is implemented by ADR0185.

## Photo save and ignore — ADR0185

✅ Camera.Capture.savePhoto and ignorePhoto reject unknown parameters and malformed/oversized UUIDs before any effect. Optional photoID selects current when omitted; neutral CameraPhotoCommandReceipt encodes saved/ignored, actual UUID and alreadySaved. save has60s cooperative budget; ignore uses ordinary finite completion. Host registration chooses observation. Native permission, identity and export belong to the injected capability.

## Phase two implementation contract - ADR0188

✅ Implemented. Assistant is the persistent default user-entry Agent and delegates photography, history and application operations through authorized communication Actions and existing task Signals. Typed UI inputs use deterministic routing; model requests use the same output and function execution path. Execution results return to the real task executor.

Support owns the reusable one-round Chat worker, native/XML communication adaptation and reply mapping, with injected identity, context and policies. Each business Agent owns independent durable history, preprocessing, capabilities and task completion. No new directory, target, dependency, Core role policy or delegation runtime is introduced.

App owns registration, transport, stable interaction lifetime and native presentation authorization. Microphone capture is a separate lifetime. Delivery acceptance, child completion and native effects remain distinct. Pending questions and artifact references are bounded and task-scoped; deletion retains existing trusted UI confirmation. Storage failures terminate dependent processing, cancellation joins owned workers, and restart interrupts without replay.

See `docs/adr/0188-specialist-task-ownership.md` for migration, capacity and validation contracts.

✅ Device regression fix: Successful open/close/flip return bounded structured command receipts (operation and acknowledged enabled/facing fields) through the same canonical functions. Receipt creation follows actual native completion and cancellation validation; native failures still propagate.

✅ Camera model exposure: Photographer declares openCamera/closeCamera/flipCamera/retryCamera alongside takePhoto/savePhoto/ignorePhoto as scheduled Camera Actions; no camera native Tool is exposed to the model. Host binds the canonical camera functions to both protocols only for explicit fixed UI transaction reuse. Model camera Actions keep observed owner-directed results and same-Channel ordering/wait groups.
