# App — Composition and Lifecycle

Assembles model capabilities, device services, Agents and presentation. The goal is one shared runtime with independent voice and camera sessions. MainActor owns presentation and coordination; actors own Agent, transport and model state.

## Directory structure

```text
App/
├── MobileHarnessApp.swift         # SwiftUI entry and startup/diagnostic selection
├── AppContainer.swift             # Model capability preparation and platform services
├── AgentBootstrap.swift           # Shared ApplicationRuntime and explicit handlers
├── AppLifecycleCoordinator.swift  # Voice session, playback and presentation state
├── CameraCoordinator.swift        # Camera intent, permissions and scene lifecycle
├── PhotographySession.swift       # Camera-frame adaptation and vision session
└── README.md                      # Composition and lifecycle contract
```

## Upstream and downstream

Arrows show requests and data, not every Swift import.

```mermaid
flowchart LR
    Experience -->|User intent| App
    PlatformKit -->|Audio, camera and device telemetry| App
    App -->|Resource root| Defaults[ModelKitDefaults / ModelManager]
    Defaults -->|Capability handles| App
    App -->|Adapted input| Input[InputGateway]
    Input --> Agents
    App -.->|Capabilities and lifecycle| Agents
    Agents --> Output[OutputGateway]
    Output --> Runtime[ActionRuntime / ToolRuntime]
    Runtime --> Handlers[App-bound Actions / Tools]
    Handlers --> PlatformKit
    Handlers -->|Accepted presentation state| Experience
```

## Internal structure and data flow

```mermaid
flowchart TD
    Entry[MobileHarnessApp] --> Container[AppContainer]
    Entry --> Camera[CameraCoordinator]
    Container --> Voice[AppLifecycleCoordinator]
    Voice --> Shared[ApplicationRuntime in AgentBootstrap]
    Camera --> Session[PhotographySession]
    Session --> Shared
    Shared --> Policy[Three JSON v4 configurations and communication policy]
    Shared --> Transport[AgentManager / InputGateway / OutputGateway]
    Shared --> Handlers[Explicit Action and Tool handlers]
    Transport --> Presentation[RuntimePresentation callbacks]
    Handlers --> Presentation
    Presentation --> Voice
    Presentation --> Camera
```

ApplicationRuntime is available before voice model preparation. App supplies the resource root to ModelKitDefaults and gets interfaces from the process-wide ModelManager; it does not register model providers. Voice prepares recognition, chat, VAD and system TTS before opening the microphone. Camera preview and its vision session start independently.

Voice PCM enters InputGateway, then SpeechPerception. Assistant subscribes to final speech and speech onset; App does not resubmit final text. Agent-selected UI changes use registered Actions or Tools. Runtime observations control admission, completion and failure supervision, never caption or expression commands. Device telemetry and local user/OS lifecycle changes remain App-owned.

Camera frames enter InputGateway through PhotographySession. VisionPerception filters frames, requests pose inference, publishes observations and emits the completion-only UI.showPose Tool. App checks camera session and frame order before updating the overlay. The default filter is 3% change with a 100 ms maximum refresh interval; this is an admission rule, not a processing-FPS guarantee.

## Concurrency and cleanup

| Work | Owner, bound and completion |
| --- | --- |
| Startup / voice stop | One serialized cleanup chain; new capture waits for old cleanup |
| Voice input and output | One capture consumer and sequential output consumers; bounded PCM/output queues belong to PlatformKit and SpeechPerception |
| Reply completion | Join admitted speech/display Actions, then wait 350 ms before resuming speech input |
| Camera changes | One reconciliation worker uses current intent; stop capture and join old analysis before replacement |
| Camera output | One sequential Tool consumer; latest-frame and display replacement belong to VisionPerception |
| Memory warnings | Capacity-one latest notification stream; one consumer forwards pressure to ModelManager |
| Audio telemetry | Capture keeps 2048 latest samples, at most 4096 during append; 32-band analysis and playback cursor polling run at most every 33 ms |

Stop closes capture and perception admission, cancels and joins producer/transport work, then cancels the session's consumers and Actions. Voice and camera close only their own sessions. Models follow ModelManager residency policy. Late UI work must pass active-session and turn/sequence checks. Failures propagate; already completed effects are not rolled back.

See [SpeechPerception](../Agents/SpeechPerception/README.md), [VisionPerception](../Agents/VisionPerception/README.md), [audio I/O](../PlatformKit/Audio/README.md) and [scheduling](../Gateway/Output/Scheduling/README.md) for queue contracts.

## Voice interruption and cancellation

✅ App coordinates session-level stopping. User stop, system audio interruption, audio route changes and voice failures enter `AppLifecycleCoordinator.stopVoice`. This is the current implementation; it does not add Agent-initiated turn cancellation.

```mermaid
flowchart TD
    Trigger["User stop / OS audio interruption<br/>Route change / Voice failure"] --> Stop["App.stopVoice"]
    Stop --> Immediate["Invalidate active voice session<br/>Cancel capture and output-dispatch tasks<br/>Stop audio device"]
    Stop --> Cleanup["Serialized cleanup task<br/>Wait for earlier cleanup and startup"]
    Cleanup --> Perception["Stop SpeechPerception<br/>Join perception and capture tasks"]
    Perception --> Send["InputGateway.send<br/>assistant.cancel for the old session"]
    Send --> Receive["Assistant.receive: immediate control handling<br/>Clear session inbox and history"]
    Receive --> Generation["Cancel and join active generation<br/>Model session.cancel"]
    Generation --> Actions["App calls OutputGateway.cancel(sessionID)"]
    Actions --> Scheduler["ChannelScheduler<br/>Remove pending actions<br/>Cancel running handlers and await return"]
    Scheduler --> Finish["Join outstanding output dispatch<br/>Remove SpeechPerception instance"]
    Immediate -.->|"Cancellation propagates through the active call"| Tool["ToolDispatcher / ToolExecutor / Tool handler"]
    classDef app fill:#DBEAFE,stroke:#2563EB,color:#1E3A8A
    classDef agent fill:#DCFCE7,stroke:#16A34A,color:#14532D
    classDef execution fill:#FEF3C7,stroke:#D97706,color:#78350F
    class Trigger,Stop,Immediate,Cleanup,Actions,Finish app
    class Perception,Send,Receive,Generation agent
    class Scheduler,Tool execution
```

The immediate stop actions and the serialized cleanup chain are distinct: audio and current tasks are stopped promptly, while cleanup awaits earlier work before completing the session teardown. The generation branch applies when Assistant has an active input from that session.

`assistant.cancel` bypasses Assistant's ordinary inbox, including when it is full or the Agent is paused. It removes queued inputs and history for that session, cancels the matching generation task and awaits its return. Generation cancellation calls the model session's cancellation API. It does not retract Actions already admitted to ChannelScheduler.

App therefore also calls `OutputGateway.cancel(sessionID)`. The scheduler removes pending Actions, signals cancellation to running handlers and waits for them to return before completing cleanup. Cancellation is cooperative; a handler that does not cooperate can delay the barrier. Completed device effects are not rolled back. Producers must stop first so that they cannot submit more work after cancellation.

| Scope | Current cancellation path |
| --- | --- |
| Assistant work for one session | InputGateway.send → assistant.cancel → clear matching inbox/history and cancel/join generation |
| Actions for one Agent/input | OutputGateway routes assistant.error or agent.error controls → ChannelScheduler.cancel(source, inputID) |
| Actions for one session | App → OutputGateway.cancel(sessionID) → ChannelScheduler |
| All Action scheduling | OutputGateway.shutdown → ChannelScheduler.shutdown; closes future admission and joins current work |
| Tool execution | Cancel the task awaiting OutputGateway.dispatch; cancellation propagates through ToolExecutor to its handler |
| Signal admission | Caller cancellation propagates through InputGateway's structured target tasks; already accepted work remains Agent-owned |

`OutputGateway.cancel(sessionID)` currently targets Actions only; it is not a session-wide Tool cancellation registry. App separately cancels the active output-dispatch task. A cancelled Tool call throws cancellation rather than returning a cancellation ToolResult, and its handler must cooperate. Normal Tool results still return through InputGateway.send.

App owns this coordination because stopping a voice session spans capture, perception, generation and device execution. Assistant owns its internal work; it currently emits no explicit cancellation output when handling assistant.cancel. ❌ Agent-initiated cancellation of its own turn/output and automatic user-speech interruption of an ongoing reply are not implemented. Reply processing currently suspends microphone data admission. If those behaviors are added, the Agent can initiate cancellation of its own output while App retains session-level teardown responsibility.

Implementation: [stopVoice](AppLifecycleCoordinator.swift), [Assistant control handling](../Agents/Assistant/AssistantAgent.swift), [output routing](../Gateway/Output/Routing/ExecutionRouter.swift), [Action cancellation](../Gateway/Output/Scheduling/ChannelScheduler.swift) and [Tool execution](../ToolRuntime/ToolExecutor.swift).

## Feature status

- ✅ Shared communication assembly, JSON v4 validation, explicit handlers and separate camera/voice sessions.
- ✅ Turn-scoped captions, semantic emotions, actual playback state and frequency telemetry.
- ✅ Explicit diagnostics and a labeled Debug-only conversation preview; the preview uses simulated state.
- ❌ Independent multi-window Agent namespaces, persistent background supervision and robot control.

## Issue record

| Status | Issue / next step |
| --- | --- |
| Open | Competing scene-role registrations fail; multi-window ownership is not implemented. |
| Open | Validate sustained camera/voice operation, startup latency and memory/thermal behavior on iPhone. |
| Resolved — 2026-09-27 audit | Consolidated repeated presentation updates and corrected skeleton execution from Action to completion-only Tool. |

✅ InternalSignalBus is removed. App assembles shared policy and gateways, stops producers and coordinates Agent/runtime cancellation and cleanup; Agent inboxes own pending messages. No communication session registry remains. Action completion barriers and independent camera/voice cleanup remain. See [ADR 0048](../../docs/adr/0048-direct-signal-admission.md).

✅ Camera gaze is owned by CameraCoordinator, independent of voice readiness. PhotographySession injects mirroring and a session-fenced moveEyes callback. ApplicationRuntime explicitly binds UI.moveEyes. Each camera Action is joined/retired via the existing ChannelScheduler after OutputGateway dispatch, before consuming the next bounded UI state; this prevents per-frame input bookkeeping leaks. The completion barrier cannot be coalesced. Off/interruption/error/session change centers gaze; old-session and non-increasing Action sequences cannot overwrite it. ❌ No face identity guarantee or no-frame timeout.
