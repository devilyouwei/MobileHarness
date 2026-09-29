# App Lifecycle

Purpose: coordinate voice and camera runtime scopes. Design goals: preserve admission, sequence fencing and producer-before-executor cleanup while keeping page state separate.

| File | Responsibility |
| --- | --- |
| VoiceSessionCoordinator.swift | Voice Agents, capture/output tasks, session/turn checks, actual playback, the voice-scope PCM cache and cleanup; receives runtime, capabilities, audio service and ConversationState |
| CameraCoordinator.swift | Permission/foreground/user intent, native camera start/stop and one vision task; receives AppleCamera, CameraState and a vision-session factory |
| VisionSession.swift | One VisionPerception Agent incarnation, frame admission and output consumption through Gateways; receives the shared runtime and PoseCapability |

CameraCoordinator has one worker and one latest desired state; newer user intent replaces pending intent. Native frames retain their existing bounded latest-frame stream. VisionSession uses App/Adapters for image conversion, awaits Tool completion and joins each admitted Action before consuming another replaceable output. These files own running scopes, not page layout or dependency registration.

```mermaid
flowchart LR
    Intent[Scene / user control] --> Scope[Session owner]
    Scope --> Producers[Capture and Agents]
    Producers --> Gateways[InputGateway / OutputGateway]
    Gateways --> Execution[Action and Tool execution]
    Execution --> Endpoint[Session-fenced effect methods]
    Endpoint --> State[UI state / platform playback]
    Stop[Stop or replacement] --> Close[Stop and join producers]
    Close --> Cancel[Cancel audio and executors; await cleanup]
    Cancel --> Release[Release role endpoint and session resources]
```

✅ Whole voice/camera endpoints bind through RuntimePresentation, with weak ownership and rejection of an occupied role. State can remain visible independently of the lifetime of a rendered page. Long-running tasks belong to the window/application host.

❌ Multi-window arbitration, non-cooperative handler preemption and autonomous background execution. No new input/event queues are introduced.
