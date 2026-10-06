# AppSpeechPlayback

Purpose: own speech application operations in an independent compilation boundary. Design goals: explicit injected effects and unchanged business lifetimes. Direct dependencies: FunctionContracts and StorageAudio.

✅ SpeechPlayback checks out one owner-scoped audio handle, awaits injected playback, and joins cancellation cleanup before release. It has no synthesis/model/device dependency or work queue.

```mermaid
flowchart LR
    Root[App composition] -->|Inject operations and services| Workflow[AppSpeechPlayback]
    Workflow -->|Actual state and completion| Consumer[UI or caller]
```

❌ No replay or audio mixing is introduced.

✅ Playback propagates neutral storage and caller-supplied producer failures after existing cleanup; host adaptation supplies user wording. ❌ No synthesis policy is implemented here.

✅ ADR0161: standard callable inputs use FunctionInput/FunctionContracts; common execution and call protocols belong to independent Gateway targets. This directory retains its existing ownership, resource/permission and lifecycle boundaries. ❌ Remaining feature Signal/continuation and physical acceptance are separate work.
