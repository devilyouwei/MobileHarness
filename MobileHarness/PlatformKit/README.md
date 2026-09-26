# PlatformKit — OS and Device Primitives

PlatformKit abstracts operating-system services, audio hardware, permissions, and external-device transport. Architecture section 34 defines its target coverage. It acquires input and performs device operations without Agent business semantics or model reasoning.

## Direct relationships

The current App supplies the wiring between PlatformKit and consumers. Arrows show logical data and operations, not direct module imports.

```mermaid
flowchart LR
    Hardware[OS and audio hardware] -->|Microphone samples and device state| PlatformKit
    PlatformKit -->|Audio operations and playback| Hardware
    PlatformKit -->|Captured PCM through App| Gateway
    Actions -->|PCM through injected playback callback| PlatformKit
    PlatformKit -->|Playback completion or failure| Actions
    App -->|Audio session and permission operations| PlatformKit
    PlatformKit -->|Availability and errors| App
```

## Implementation status

- ✅ `Audio/AppleAudioIO.swift`: Apple audio capture, playback, and platform operations.
- ✅ `Audio/StreamingMonoPCMResampler.swift`: continuous mono PCM conversion with stream-local filter state and conversion errors.
- ✅ `Audio/MicrophoneFrame.swift`: shared captured PCM and level measurements. Segmentation is owned by Gateway using VAD probabilities; the obsolete energy segmenter and batch resampler have been removed.
- ✅ `Device/DeviceCapability.swift`: capability, authorization, and permission interfaces.
- ✅ `ExternalDevice/ExternalDeviceTransport.swift`: connect, send, emergency-stop, and disconnect contracts.
- ❌ Concrete Sensors, Storage, Network, BLE, robot, and IoT adapters.
- ❌ Real robot integration and hardware safety validation; transport protocols alone do not establish either.
- ✅ [`ExternalDevice`](ExternalDevice/README.md) `NexArmJointCommand` and `NexArmController` build and send the six-position aim frame. The home table is provisional raw 2048. ❌ The Wi-Fi socket is not opened. See [ADR 0037](../../docs/adr/0037-photographer-aim.md).

External input enters through InputGateway; Agent device actions must pass through OutputGateway and runtime execution. Use public APIs and validate capabilities and permissions. Robot emergency-stop and disconnect protection must be enforced by the device, without relying on iOS background execution.

## Maintenance

Keep this README synchronized with changes to responsibilities, files, interfaces, and implementation status. ✅ means implemented; ❌ means planned or incomplete. Do not create unused placeholder modules. The [technical architecture](../README.md) defines the target; the [layout audit](../../docs/Repository-Structure.md) records implementation exceptions.

✅ Camera/AppleCamera provides actor-owned video-only preview capture, front/back switching and authorization. It does not configure the shared audio session or request microphone access. ❌ Recording is not implemented.

✅ Camera now exposes bounded upright RGB frames (max 640 per side) in addition to preview. Late native frames and an older queued frame may be replaced; no Agent/model dependencies are introduced.
