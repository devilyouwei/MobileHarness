# PlatformKit — Device Input and Output

Purpose: provide reusable hardware and operating-system I/O through public APIs. Design goals: permission-aware device lifetimes, bounded data/command admission, explicit cleanup and an independent foundational SDK. PlatformKit depends only on shared Types values; it has no business or model dependency.

| Directory | Owns | Must not own |
|---|---|---|
| [Core](Core/README.md) | Documentation for future shared contracts; no compiled implementation | Business decisions or device workflow orchestration |
| [Audio](Audio/README.md) | Capture, PCM conversion, native playback, measured spectrum | Speech Actions, model inference, conversation policy or UI animation choices |
| [Vision](Vision/README.md) | Camera lifecycle, native preview binding, bounded frames and orientation-aware samples | Gesture/pose decisions, model inference, overlay content or preview cropping policy |
| [Connectivity](Connectivity/README.md) | Links, device protocols, native command encoding, telemetry and connection diagnostics | Action wrappers, reset/home choices, motion recipes, preferred device ordering or localized UI messages |

```mermaid
flowchart LR
    Actions[Actions: behavior and completion policy] --> SDK[PlatformKit: device capabilities]
    App[App: lifecycle and typed adapters] --> SDK
    SDK <--> Hardware[OS / external hardware]
    SDK --> Facts[Frames / PCM / telemetry / structured failures]
    Facts --> App
    App --> Consumers[Agents and presentation through owned interfaces]
```

✅ Audio capture/playback, stream resampling and FFT metering; foreground camera capture/preview and bounded native-frame delivery; adapter-owned authorization; NexArm USB/BLE and protocol support are implemented. Playback drain and transport admission describe device operations, not a business Action result. Fixed buffer capacities and hardware register ranges are capability constraints, not application choreography.

## Ownership boundary

Manual jog/reset behavior, gestures and motion completion policy belong to Actions/NexArm/Support. App workflows own Bluetooth ordering/localization; App adapters choose preview layout. PlatformKit exposes native capabilities and device facts without selecting application behavior.

❌ Additional device domains, general network transport, recording and a confirmed independent robot emergency-stop mechanism are not implemented. Physical safety cannot depend on App background execution.
