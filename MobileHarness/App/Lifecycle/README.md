# App Lifecycle

Purpose: coordinate voice and camera runtime scopes. Design goals: preserve admission, sequence fencing and producer-before-executor cleanup while keeping page state separate.

| File | Responsibility |
| --- | --- |
| VoiceSessionCoordinator.swift | Voice Agents, capture/output tasks, session/turn checks, actual playback, the voice-scope PCM cache and cleanup; receives VoiceRuntimeDependencies, capabilities, audio service and ConversationState |
| CameraCoordinator.swift | Permission/foreground/user intent, native camera start/stop and one vision task; receives AppleCamera, CameraState and a vision-session factory |
| VisionSession.swift | One VisionPerception Agent incarnation, frame admission and output consumption through Gateways; receives VisionRuntimeDependencies and an injected Agent factory |

CameraCoordinator has one worker and one latest desired state; newer user intent replaces pending intent. Native frames retain their existing bounded latest-frame stream. VisionSession uses App/Adapters for image conversion, awaits Tool completion and joins each admitted Action before consuming another replaceable output. These files own running scopes, not page layout or dependency registration.

```mermaid
flowchart LR
    Intent[Scene / user control] --> Scope[Session owner]
    Scope --> Producers[Capture and Agents]
    Producers --> Gateways[InputGateway / OutputGateway]
    Gateways --> Execution[Action and Tool execution]
    Execution --> Endpoint[Session-fenced effect methods]
    Execution --> Done[Reply completion or cancellation barrier]
    Done --> Retire[Retire remaining source/input audio]
    Endpoint --> State[UI state / platform playback]
    Stop[Stop or replacement] --> Close[Stop and join producers]
    Close --> Cancel[Cancel audio and executors; await cleanup]
    Cancel --> Release[Release role endpoint and session resources]
```

✅ Whole voice/camera endpoints bind through RuntimePresentation, with weak ownership and rejection of an occupied role. State can remain visible independently of the lifetime of a rendered page. Long-running tasks belong to the window/application host.

❌ Multi-window arbitration, non-cooperative handler preemption and autonomous background execution. No new input/event queues are introduced.

## Action runtime stage 2

✅ CameraCoordinator acquires a 60-second camera.capture lease, renews every 10 seconds and fences camera start. Stop/lens/background transitions release the lease through centralized stop acknowledgment. Faults remain blocked until explicit retry/recovery; stale local cleanup cannot stop a newer owner. Latest capture ActivityEvent is host telemetry, not a recording Action or model turn. ❌ No generic activity event stream or real-device takeover acceptance.

## Domain-owned behavior assembly

✅ VoiceSessionCoordinator and VisionSession no longer await prepareTools; the complete Tool registry is validated during ApplicationRuntime construction. Existing voice/camera ownership, join order and physical effects remain unchanged. ❌ This migration does not add device functionality.

## Action implementation audit

✅ VoiceSessionCoordinator implements typed play(audioID:invocation:) and delegates checkout/drain/release to SpeechPlayback. Audio argument decoding belongs to SpeechActions.speak.

✅ Structured Action failures are labeled as action failures rather than generic speech-processing failures. NexArm argument errors provide localized descriptions instead of exposing Swift error type names. Cancellation and input cleanup behavior remain unchanged.

## Action and Tool presentation boundary

✅ Caption append, full transcript replacement, voice phase and gaze endpoints consume ToolInvocation. The existing session/turn acceptance policy remains; expression and audio keep scheduled Action contexts. ❌ No audio/recognition errors are inserted into the Action panel.

✅ VoiceSessionCoordinator retires source/input audio after successful dispatch of reply completion/error controls, when Gateway has joined the corresponding Actions. Dispatch failure also retires that input; voice interruption still stops the producer before cancelling all audio in that session. Pending/ready PCM has no wall-clock expiry. Consumed frames already leave Storage on read, and each played handle is released after hardware drain; reply cleanup retires only remaining handles. The production store has no PCM read timeout; the synthesis worker owns its 60-second execution deadline, excluding queue time. The voice session spans multiple replies; current voice admission allows one reply through playback at a time, while cache ownership still isolates other sources and inputs. ❌ Generation completion alone is not playback completion, and this does not add barge-in or multi-reply UI.

✅ Voice/camera endpoints consume independent Action/Tool contexts. AppWorkflows owns conversation policy and stored-audio playback adaptation; lifecycle owners retain actual session and device state.

✅ Reply cleanup converts OutputEnvelope.source to its raw string at the StorageAudio boundary, retaining source/input-scoped cancellation.

✅ ADR0098: RuntimeDependencies supplies immutable voice/vision/camera service slices instead of ApplicationRuntime. Composition injects Agent factories; registration, input/output pumps, barriers and cleanup remain owned here.

✅ CameraCoordinator implements explicit setEnabled/flip Tool controls. Foreground and idle-worker admission are required; overlap fails busy, flip while disabled fails. Completion waits for reconciliation and checks revision, permission and capture state. Scene/UI supersession fails cancellation; close joins capture release and vision cleanup. VoiceSessionCoordinator validates Assistant source and active voice session. ❌ Open capture does not prove pose inference readiness; admitted intent is not rolled back on caller cancellation.

✅ VisionSession registers Photographer alongside the injected vision Agent, dispatches both output streams, and removes both during joined session cleanup.
