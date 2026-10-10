# App Lifecycle

Purpose: coordinate voice and camera runtime scopes. Design goals: preserve admission, sequence fencing and producer-before-executor cleanup while keeping page state separate.

| File | Responsibility |
| --- | --- |
| VoiceSessionCoordinator.swift | Voice Agents, capture/output tasks, session/turn checks, actual playback, the voice-scope PCM cache and cleanup; receives VoiceRuntimeDependencies, capabilities, audio service and ConversationState |
| AudioDetectionSession.swift | Isolated microphone/source-only Agent session, Gateway pumps, native-fact/UI projection and joined shutdown |
| CameraCoordinator.swift | Permission/foreground/user intent, native camera start/stop and one vision task; receives AppleCamera, CameraState and a vision-session factory |
| VisionSession.swift | One VisionPerception Agent incarnation, frame admission and output consumption through Gateways; receives VisionRuntimeDependencies, the injected vision factory and root Photographer transport |

✅ VoiceSessionCoordinator enters listening only after AppleAudioIO confirms actual PCM delivery. A failed capture or unexpectedly ended stream clears the microphone spectrum and enters the failed presentation phase, retaining the existing independent Assistant/Synthesis scope. Closing capture admission also rejects in-flight voice-state Tools so they cannot restore listening after failure. Generation checks after asynchronous capture shutdown prevent old failures from changing a replacement session. ❌ Physical microphone restart and spatial/camera/playback coexistence still require device acceptance.

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

✅ CameraCoordinator acquires a 60-second camera.capture lease, renews every 10 seconds and fences camera start. Stop/lens/background transitions release the lease through centralized stop acknowledgment. Capture failure requires normal camera retry; resource ownership has no persistent fault/recover state. Cleanup timeout fails its request and retains unfinished work until actual completion automatically unlocks; stale local cleanup cannot stop a newer owner. Latest capture ActivityEvent is host telemetry, not a recording Action or model turn. See [resource ownership](../../Gateway/Output/Resources/README.md). ❌ No generic activity event stream or real-device takeover acceptance.

## Domain-owned behavior assembly

✅ VoiceSessionCoordinator and VisionSession no longer await prepareTools; the complete Tool registry is validated during ApplicationRuntime construction. Existing voice/camera ownership, join order and physical effects remain unchanged. ❌ This migration does not add device functionality.

## Action implementation audit

✅ VoiceSessionCoordinator implements typed play(audioID:invocation:) and delegates checkout/drain/release to SpeechPlayback. Audio argument decoding belongs to SpeechActions.speak.

✅ Structured Action failures are labeled as action failures rather than generic speech-processing failures. NexArm argument errors provide localized descriptions instead of exposing Swift error type names. Cancellation and input cleanup behavior remain unchanged.

## Action and Tool presentation boundary

✅ Caption append, full transcript replacement, voice phase and gaze endpoints consume FunctionInput. The existing session/turn acceptance policy remains; expression and audio keep scheduled Action contexts. ❌ No audio/recognition errors are inserted into the Action panel.

✅ VoiceSessionCoordinator retires source/input audio after successful dispatch of reply completion/error controls, when Gateway has joined the corresponding Actions. Dispatch failure also retires that input; voice interruption still stops the producer before cancelling all audio in that session. Pending/ready PCM has no wall-clock expiry. Consumed frames already leave Storage on read, and each played handle is released after hardware drain; reply cleanup retires only remaining handles. The production store has no PCM read timeout; the synthesis worker owns its 60-second execution deadline, excluding queue time. The voice session spans multiple replies; current voice admission allows one reply through playback at a time, while cache ownership still isolates other sources and inputs. ❌ Generation completion alone is not playback completion, and this does not add barge-in or multi-reply UI.

✅ Voice/camera endpoints consume independent Action/Tool contexts. AppWorkflows owns conversation policy and stored-audio playback adaptation; lifecycle owners retain actual session and device state.

✅ Reply cleanup converts OutputEnvelope.source to its raw string at the StorageAudio boundary, retaining source/input-scoped cancellation.

✅ ADR0098: RuntimeDependencies supplies immutable voice/vision/camera service slices instead of ApplicationRuntime. Composition injects Agent factories; registration, input/output pumps, barriers and cleanup remain owned here.

✅ CameraCoordinator implements explicit setEnabled/retry/flip(CameraActions.Facing) controls. Flip selects front/back; healthy same-target selection completes without restarting capture. Foreground and idle-worker admission are required; overlap fails busy, flip while disabled fails. Completion waits for reconciliation and checks revision, permission and capture state. Scene/UI supersession fails cancellation; close joins capture release and vision cleanup. RuntimePresentation validates the actual Photographer and active stable root/task scope. ❌ Open capture does not prove pose inference readiness; admitted intent is not rolled back on caller cancellation.

✅ VisionSession registers VisionPerception and attaches its UUID to root-owned Photographer. Joined cleanup detaches tracking and removes VisionPerception; root camera control remains alive.

✅ PhotographerIntentRuntime is injected from composition. VisionSession tracks successful attachment and cleans up only its own vision/attached tracking scope after partial activation failure.

✅ VisionSession treats tracking outputs as an independent subscriber. Each failed Tool is retained by the independent OutputGateway failure observer for the home scheduling issue list and does not stop frames, VisionPerception or showPose. Subscriber completion does not end the camera task group; cancellation still joins both producers. ❌ Physical tracking acceptance remains pending.

✅ Voice and vision consumers use nonfatal Gateway execution outcomes. SpeechPerception failure stops only its capture worker and own actor, preserving Assistant/SpeechSynthesis lifetime; session/user cancellation retains full cleanup.

✅ Vision failure updates only visionStatus and stops its frame admission; Photographer remains root-owned after camera session cancellation; only that tracking scope retires. Capture/recognition failure does not cancel Assistant or Synthesis.

✅ Assistant terminal failure leaves independently registered perception/synthesis alive; the host lifetime waits for explicit cancellation before full cleanup. Its idle wait has no producer and an explicit capacity1. Recognition resume failure stops only recognition/capture.

✅ Expression adaptation has capacity one override and one continuation, rejecting conflicting activation. SwiftUI transaction IDs acknowledge actual animation completion; cancellation, renderer disappearance, new turn and stop resume the waiter exactly once. Restoration is invocation-fenced and uses the current base. UI.Expression.express composition belongs to Actions; setExpression commits persistent state. ❌ Physical animation acceptance remains pending.

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

✅ CameraCoordinator now maps Actions.PoseOverlay into UI/Camera values; Tool and session/sequence semantics remain unchanged.

✅ VoiceSessionCoordinator and VisionSession use MediaInputAdapter for explicit device-source/deadline admission. Published generic messages are extracted as typed business PerceptionMessage only in the App observer; session/turn checks and shutdown joins are preserved.

✅ CameraCoordinator owns captureResource (camera.capture); AgentCore ResourceID remains device-neutral. Composition registers that same host-owned identity. ❌ No additional capture owner.

✅ ADR0119: App transports native camera frames and native-rate microphone samples with session/source/deadline metadata. Calling perception Agents own conversion into ModelKit inputs; composition no longer injects image conversion. SDK inputs/outputs are owned by ModelKit or PlatformKit, without Types dependencies. ❌ No physical-device acceptance is implied.

✅ CameraCoordinator reports out-of-order presentation admission with CommunicationError.outOfOrder; AgentCore ImageInputError is limited to malformed frame values. ❌ No camera or model lifetime changes.

✅ ADR0121 removes the Types module: AgentCore/Input owns generic audio/image transport, UI/Camera owns PoseOverlay, and VisionPerception owns PoseOverlayPayload. App adapts the independent Tool payload into UI values. ❌ Capability SDKs must not import consumer or presentation modules.

✅ VoiceSessionCoordinator requests spatial-capable microphone capture, transports native layout/PTS/monotonic capture time through InputGateway and uses W only for existing spectrum telemetry. Existing reply admission suppresses all sound/ASR inputs. Voice cleanup awaits async microphone shutdown; SpeechDiagnosticWorkflow also joins audio cleanup. ❌ No sound direction is consumed or presented by App; route/coexistence acceptance remains physical-device work.

## Isolated audio detection session

✅ AudioDetectionSession.swift owns the entire diagnostic capture/perception endpoint: a fresh AppleAudioIO, session ID, AgentManager and both Gateways, with only SpeechPerception registered in soundSourceOnly mode. All PCM goes through MediaInputAdapter/InputGateway and direction through the bound publish port/OutputGateway observer. App maps SDK facts and observations into UI values; it contains no direction DSP. Native meter snapshots are latest replaceable values, at most 10 Hz; raw PCM admission retains explicit rejection. Route changes and interruptions stop the attempt for explicit retry, rather than silently updating layout/input. No Assistant, Photographer, conversation recording, playback or robot execution is registered.

✅ Composition supplies mutual voice/diagnostic cleanup barriers. Starting diagnostics stops and joins admitted voice work; starting voice cancels and joins diagnostics before microphone setup. A pending voice start is not recursively joined by diagnostic pre-start cleanup. Shutdown closes UI updates, cancels/joins output handling and Agent publication, stops hardware and removes the isolated registration before replacement.

❌ Physical transitions, microphone permission/route behavior and camera coexistence remain device acceptance items.

✅ ADR0131: VisionSession continues processing after ordinary tracking output failure; OutputGateway records those failures for the home scheduling issue list. CameraCoordinator exposes no tracking error banner endpoint. BLE recovery does not stop voice/session scheduling. ❌ Physical coexistence acceptance remains pending.


✅ ADR0141 removes CameraCoordinator's faulted/recover flag and branch. Retry performs normal lease acquisition against current occupancy; late completed cleanup unlocks automatically. Cancelled lifecycle removal and closure during an existing handoff still await bounded coordinator-owned acknowledgment. Camera capture leases retain deadlines, renewals and stale-lease checks. ❌ Software closure does not establish physical device stop.

✅ Voice playback adapts known producer/storage failures to user wording only after SpeechPlayback cleanup; cancellation and unknown errors propagate unchanged. ❌ No new lifecycle owner or Agent intent route is added.

✅ ADR0157: canonical executable definitions and shared outcomes replace duplicate protocol metadata; consumers import Actions/FunctionContracts. Protocol request views remain adapters, and production permission/resource boundaries are preserved.

❌ Physical acceptance and additional business capability exposure are not established by this migration.

✅ ADR0159 — Unified invocation: all business functions, injected capabilities and registered handlers receive FunctionInput with ActionExecutionContext. Native request/result normalization stays in Runtime/Gateway; no protocol-specific implementation signature remains.

✅ ADR0160: callable functions and shared producer failures are independent of call protocols. This directory consumes the appropriate pure function/shared invocation or registration adapter at its existing boundary; host profiles own protocol selection. ❌ Broader feature Signal migration and physical acceptance remain separate.

✅ ADR0161: standard callable inputs use FunctionInput/FunctionContracts; common execution and call protocols belong to independent Gateway targets. This directory retains its existing ownership, resource/permission and lifecycle boundaries. ❌ Remaining feature Signal/continuation and physical acceptance are separate work.

✅ ADR0163: host camera activity events carry an explicit lease-scoped causal root shared across that activity's states. No Agent input exists on the current host camera route; Agent-controlled camera entry migration remains pending. Capture/renewal/cleanup algorithms are unchanged.

✅ Microphone stop retires capture/perception only. The App-owned interaction lifetime retains the default Assistant, specialists and reply consumer; full application shutdown cancels/joins these owners. AgentSessionControl preserves the legacy wire contract for explicit session controls.

✅ ADR0171: scene activity controls resource observation independently of voice/camera. Background invalidates old resource presentation and cancels sampling; reactivation waits for the existing worker to finish before another starts. SDK background downloads remain independent.


## Camera command entry

✅ Implemented: CameraInteractionWorkflow emits typed open/close/flip/retry intents through Photographer and existing Camera functions. Root presentation accepts Photographer in the stable root session or validated active task scope; Assistant delegates through task communication; Photographer executes under its actual identity. Native capture, permission, lifecycle fences and joined cleanup remain CameraCoordinator responsibilities. Retry uses a canonical callable and the native explicit settings/permission request. UI receives controls and passive camera state, not the native coordinator. One command slot rejects overlap, no replay.

✅ ADR0181: VisionSession owns VisionPerception only and attaches one vision UUID to the root Photographer transport. Cleanup detaches/reset tracking, joins its worker and cancels that vision session without stopping Photographer or its root camera command. Camera validation allows the actual Photographer in the stable interaction scope or an authorized active child task. Native camera algorithms remain unchanged.

✅ Interaction refinement: CameraCoordinator selects requested front/back, keeps permission/busy/revision checks and joins reconciliation. VoiceSessionCoordinator retains final ASR text, marks it finalized and clears both captions only on an accepted newer turn or new voice-session start; stopping voice retains the current captions.

✅ Interaction cleanup: Removed unused CameraCoordinator CameraControlling conformance and direct toggle/switch entry points; CameraInteractionWorkflow is the sole manual camera command adapter. Same-facing completion uses existing revision/foreground/capture checks.

## Action/Tool generation rounds — ADR0183


✅ BehaviorAssembly projects immutable host feedback policies. IndependentOutputWorkflow admits Actions in order while executing up to four Tools concurrently; VoiceSessionCoordinator owns, cancels and joins all dispatch tasks independently of page lifetime.

❌ Live-model, native UI and physical-device acceptance remain pending; native/XML task delegation and specialist loops are implemented. See [ADR0183](../../../docs/adr/0183-generation-round-observations.md).

## Assistant photo observation — ADR0184

✅ Implemented: CameraCoordinator owns one photo task independent of UI page, guards foreground/capture/revision and joins cancellation. Store JPEG and a display preview, then await bounded UI animation completion. Durable capture remains when presentation fails.

❌ Real camera/shutter/animation and configured-model vision acceptance remain pending; video recording remains outside this iteration; system Photos export is implemented by ADR0185.

✅ Recognition admission follows actual playback and350ms tail protection, including model/ReACT wait. A confirmed utterance finishes bounded ASR before playback begins. Semantic final/phase Signals use the stable interaction scope; raw audio/partial recognition retain capture generation. A model failure does not stop unrelated capture or specialists; microphone stop does not cancel Agent tasks.

## Photo save and ignore — ADR0185

✅ CameraCoordinator retains (photoID, original StorageOwner) for the displayed capture. savePhoto freezes/validates the selected UUID, reads original JPEG and owns one cancellable/joined export Task; capture/export overlap fails busy. Confirmed album import sets savedPhotoID before returning, preventing duplicate writes while displayed. Ignore requires an acknowledged current thumbnail, hides it and clears its owner without exporting or deleting album data. Camera can be off; foreground is required. Scene/camera reconciliation cancels export and cleanup joins the OS transaction. Permission failure retains the thumbnail; committed exports remain real facts after cancellation. Private evidence remains bounded32 files/128MiB; deletion/gallery are outstanding.

## Lens switch latency correction

✅ Implemented: CameraCoordinator marks healthy flip revisions for native input replacement through the existing resource lease. Native completion restores preview and finishes the command without waiting for old inference/tracking teardown. A root-owned bounded CameraVisionRestartWorkflow cancels/joins old vision and keeps only the latest frame-stream intent; replacement starts only after old endpoint/Agent removal. Off/background/model maintenance invalidates and joins this worker. Failure stops capture and requires explicit retry; no success fallback.

❌ Physical-device switch latency, repeated flips during inference and camera/voice coexistence remain unverified.


## History image thumbnails

✅ Implemented: CameraCoordinator receives the existing photo store from composition instead of creating its own instance. Exact source/session/input checks for live photo observations remain intact. History shares the store independently of camera capture/visibility lifetime.

❌ Native image/layout and live-model acceptance remain separate from automated verification.

## Agent composition — ADR0187

✅ Agent 自有预处理、版本化结构化 Context 和 Builder 已接入；共享机制在现有 Agents/Support/Core 与 Agents 目录中。业务职责保持当前分界。函数结果按运行时捕获的执行所有者定向返回，通信投递回执只表示接纳；模型续轮不订阅自身广播。

✅ 上下文采用有界原子提交，重启将未完成工作标为中断，不重放设备动作。普通输入、反馈和控制分别接纳；所有容量或持久化失败显式返回。音视频和原生会话保持有界临时状态。

✅ 第二阶段已实现独立摄影 LLM、正式任务委派及任务定向后续输入。❌ 真实模型、原生 UI、真机语音验收仍待完成。

运输生命周期独立于页面。函数、通信、模型输出分支有界并在 round/terminal 屏障加入；生产输出在订阅时绑定真实 Agent 实例。ConversationPresentation 分开识别语句与回复身份（source/task/decision/turn）；后来的识别清理上一轮可见字幕，但不取消正在回复的任务或改变其执行身份。播放授权由真实输出源、活跃任务/会话和函数注册共同验证；SpeechPerception 在最终 ASR 发布前以及交互回复占用期间暂停新语句识别，覆盖模型等待及委派回复；实际播放与350ms尾音保护是额外恢复屏障。用户关闭时停止物理录音，策略暂停时保留原生采集并关闭帧接纳/ASR，不发新识别文本。

设计与阶段边界见 [ADR0187](../../../docs/adr/0187-agent-composition-and-react.md)；验证见 [Validation-History](../../../docs/Validation-History.md)。

## Phase two implementation contract - ADR0188

✅ Implemented. Assistant is the persistent default user-entry Agent and delegates photography, history and application operations through authorized communication Actions and existing task Signals. Typed UI inputs use deterministic routing; model requests use the same output and function execution path. Execution results return to the real task executor.

Support owns the reusable one-round Chat worker, native/XML communication adaptation and reply mapping, with injected identity, context and policies. Each business Agent owns independent durable history, preprocessing, capabilities and task completion. No new directory, target, dependency, Core role policy or delegation runtime is introduced.

App owns registration, transport, stable interaction lifetime and native presentation authorization. Microphone capture is a separate lifetime. Delivery acceptance, child completion and native effects remain distinct. Pending questions and artifact references are bounded and task-scoped; deletion retains existing trusted UI confirmation. Storage failures terminate dependent processing, cancellation joins owned workers, and restart interrupts without replay.

See `docs/adr/0188-specialist-task-ownership.md` for migration, capacity and validation contracts.


## One-way publication and listening admission correction


✅ Implemented: one-way external intent loss is bounded by a 120-second business-result watchdog, owned and joined by the existing operation. Camera cancellation acknowledgment waits at most two seconds and reports unconfirmed cleanup; it never fabricates device stop or replays work. Listening Action completion means policy accepted; microphone model preparation remains the owned startup task and is cancellable by user-off.

✅ Implemented: Listening Action acknowledges policy without awaiting an utterance. The App owns a separately cancellable pause task, fenced by command revision and capture generation. A newer command cancels/joins old pause work; user-off stops capture before joining it. Native cleanup cancels and joins pause tasks; SpeechPerception joins its own recovery task. Existing canonical serialization remains, but no utterance wait retains its lease.

## Listening policy ownership

✅ VoiceSessionCoordinator registers SpeechPerception once for the runtime lifetime, consumes outputs while capture is off, and opens/closes capture epochs without removing the Agent. Speech.Listening commands require the actual SpeechPerception/root session and monotonic revision. Native startup, confirmed-utterance pause, playback count and350ms tail remain owned execution barriers; cleanup joins capture/pause/startup and reports revision-fenced speech.captureEnded. App no longer owns orphan-final recovery or reply occupancy. Recognition failures do not terminate capture; OS/native capture termination does.

❌ True-device acoustic echo, tail, route/interruption and native UI acceptance remain pending.


✅ Recognition-caption rollover: VoiceSessionCoordinator routes accepted caption/voice updates through the shared ConversationPresentation state projection. A newer recognized turn clears both previous captions and transcriptFinalized before its first update; rejected or same-turn updates do not reset state. Session/capture guards and Agent task/playback ownership are unchanged.


✅ Reply/lifecycle regression correction: caption focus is presentation only and cannot cancel an authorized queued/playing reply from another Agent. Playback checks active session and explicit task cancellation, retaining Gateway owner/task/function authorization and the shared serialized Speech Channel. ApplicationControl accepts environment facts and correlated feedback while paused; fresh business commands still require running. Assistant delegation prompts emit send without redundant spoken acknowledgments and leave specialist speech to its executor. Scope/result delivery failures retain actual evidence; no silent error suppression or action replay is added. Add owner-switch playback admission and paused environment regressions.


✅ Camera perception/context change (2026-10-10): CameraCoordinator exposes actual capture occupancy through existing CameraState.photoBusy for the lifetime of its owned capture task; defer clears it on success/failure/cancellation. App adapts these native facts into passive Signals; lifecycle and native safety stay here.
