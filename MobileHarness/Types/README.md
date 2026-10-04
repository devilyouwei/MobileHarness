# Types — Shared values

Purpose: own shared immutable Sendable values used by independent SDKs. Design goals: group contracts by domain under one Types compilation target; retain validation at construction and keep runtime/service ownership in consumers.

| Directory | Implemented contracts |
| --- | --- |
| [Vision](Vision/README.md) | Shared pose observations, skeleton presentation and detection statistics |
| [Speech](Speech/README.md) | Speech phases and validated synthesis requests |
| [Audio](Audio/README.md) | PCM formats/frames, microphone samples and validation errors |

```mermaid
flowchart LR
    ModelKit --> Types
    PlatformKit --> Types
    StorageAudio --> Types
    Types --> Audio[Audio values]
    AgentCore --> Types
    Types --> Speech[Speech values]
    Types --> Vision[Vision values]
```

## Contracts and scope

✅ Types has no project dependencies. Audio values own PCM validation and immutable samples/format/sequence data. ModelKit re-exports audio values with its public constructor labels and CapabilityError mapping; PlatformKit re-exports MicrophoneFrame.

ImageFrame and NativeImageBuffer currently belong to ModelKit/Core. Types owns no capture, inference, persistence, queues or lifecycle services.

✅ Vision owns PoseOverlay values shared by Agents, App and UI; no preview projection or execution policy.

❌ Additional shared categories are not implemented. A category is added only with concrete values and consumers.
