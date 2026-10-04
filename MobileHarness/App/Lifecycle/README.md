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

✅ Photographer construction is injected from composition. VisionSession tracks successful registration and cleans up its own Agents after partial activation failure; it never removes a pre-existing Photographer after registration rejection.

✅ VisionSession treats tracking outputs as an independent subscriber. Each failed Tool is reported through session-scoped tracking status and does not stop frames, VisionPerception or showPose. Subscriber completion does not end the camera task group; cancellation still joins both producers. ❌ Physical tracking acceptance remains pending.

✅ Voice and vision consumers use nonfatal Gateway execution outcomes. SpeechPerception failure stops only its capture worker and own actor, preserving Assistant/SpeechSynthesis lifetime; session/user cancellation retains full cleanup.

✅ Vision failure updates only visionStatus and stops its frame admission; Photographer remains independently registered until explicit camera session cancellation. Capture/recognition failure does not cancel Assistant or Synthesis.

✅ Assistant terminal failure leaves independently registered perception/synthesis alive; the host lifetime waits for explicit cancellation before full cleanup. Its idle wait has no producer and an explicit capacity1. Recognition resume failure stops only recognition/capture.

✅ Expression adaptation has capacity one override and one continuation, rejecting conflicting activation. SwiftUI transaction IDs acknowledge actual animation completion; cancellation, renderer disappearance, new turn and stop resume the waiter exactly once. Restoration is invocation-fenced and uses the current base. UI.express composition belongs to Actions; setExpression commits persistent state. ❌ Physical animation acceptance remains pending.

## Conversation Tool execution evidence

✅ VoiceSessionCoordinator consumes OutputGateway.execute's outcome and journals only previously recorded native model calls through StorageChat. It records returning ToolResponse values/errors, completion-only success and cancellation using the original input ID and runtime call UUID. Recording failures are explicitly reported in runtime status; execution is never replayed. Generation status is independent of Tool completion. Internal UI Tools and non-journal inputs do not create records.
❌ Durable native call transcripts from older app versions cannot be reconstructed.

## Local model resources — current contract

✅ CameraCoordinator.pauseVisionForModelMaintenance cancels/joins pose work while retaining native preview. App uses voice settings-change stop/join hooks for explicit removal. Management reserves all referencing resource admission barriers before quiescence and retains them through unload/removal; old capability handles cannot reload inside that interval. Download completion never starts recording or inference automatically.

✅ MobileHarnessApp forwards native ZIP and HF background session events and restores generation-bound task associations independently of page navigation. App composition injects the same ModelKitHub adapter. HF preserves completed files and available system resume data across relaunch; explicit cancel/delete drains before discarding staging. A bounded App preparation window supports metadata/final installation. Phone/server-resume acceptance remains pending; no background robot execution is granted.

❌ OS background scheduling/force quit, full iPhone acceptance and HF durable background recovery remain outstanding. See [Management](../../ModelKit/Management/README.md#local-model-resources--current-contract).

✅ Rejected model calls remain Gateway execution outcomes and do not stop the voice session. Assistant attempts to persist native Tool parse failures before output; recording failure produces a separate nonterminal Gateway outcome, while the original rejection is still emitted. ❌ No automatic model repair is performed.

✅ VisionSession forwards the native monotonic capture instant through ImageInput. CameraCoordinator converts optional Tool pose statistics to shared UI values under the existing session/sequence checks; clearing the skeleton also clears statistics. No additional tasks or direct Agent telemetry callbacks are introduced.

✅ App injects FrameSamplingConfiguration with validated default 0...250ms adaptive bounds and a 100ms initial interval. CameraCoordinator no longer owns percentage threshold state/control or restarts sessions for threshold edits; frame retention and inference cadence remain VisionPerception responsibilities.

✅ CameraCoordinator maps optional detectionIntervalMilliseconds with the existing statistics; UI receives measured values through the same session/sequence-fenced Tool endpoint. Adaptation remains entirely inside VisionPerception.

✅ CameraCoordinator maps imageMotion through the existing whole-camera endpoint; analysis, ROI/noise adaptation, timing-budget feedback and stale-frame/result decisions remain in VisionPerception. No camera-frame preprocessing or scheduling policy is added to App.

✅ Urgent YOLO detection now permits a zero scheduling interval. The single inference worker processes only the newest pending capture after the active call completes. Normal inference duration adds no scheduling floor; compute-dominated freshness pressure can temporarily impose a bounded cost floor. Camera close already clears skeleton and its statistics; no source-stall timer is added.

✅ CameraCoordinator now maps ToolPoseOverlay into UI/Camera values; Tool and session/sequence semantics remain unchanged.

✅ VoiceSessionCoordinator and VisionSession use MediaInputAdapter for explicit device-source/deadline admission. Published generic messages are extracted as typed business PerceptionMessage only in the App observer; session/turn checks and shutdown joins are preserved.

✅ CameraCoordinator owns captureResource (camera.capture); AgentCore ResourceID remains device-neutral. Composition registers that same host-owned identity. ❌ No additional capture owner.

✅ ADR0119: App transports native camera frames and native-rate microphone samples with session/source/deadline metadata. Calling perception Agents own conversion into ModelKit inputs; composition no longer injects image conversion. SDK inputs/outputs are owned by ModelKit or PlatformKit, without Types dependencies. ❌ No physical-device acceptance is implied.

✅ CameraCoordinator reports out-of-order presentation admission with CommunicationError.outOfOrder; AgentCore ImageInputError is limited to malformed frame values. ❌ No camera or model lifetime changes.

✅ ADR0121 removes the Types module: AgentCore/Input owns generic audio/image transport, UI/Camera owns PoseOverlay, and VisionPerception owns PoseOverlayPayload. App adapts the independent Tool payload into UI values. ❌ Capability SDKs must not import consumer or presentation modules.
