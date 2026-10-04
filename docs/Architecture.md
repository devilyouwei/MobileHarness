# MobileHarness architecture

MobileHarness uses an iPhone as the host for a **Signal → Cognition → Action** loop. Microphone/camera input becomes observations; stateful Agents use model capabilities to interpret them and select behavior. Validated Actions and Tools produce speech, presentation and connected-device effects.

```mermaid
flowchart LR
    Devices[Microphone / camera / user input] --> Input[InputGateway]
    Input --> Agents[Perception and cognitive Agents]
    Agents <--> Models[Model capabilities: local or explicit cloud chat]
    Agents --> Output[OutputGateway]
    Output --> Behaviors[Actions / Tools]
    Behaviors --> Effects[Speaker / UI / connected robot]
    Output -->|observations and results| Input
```

## Perception and cognition

SpeechPerception and VisionPerception share recognition/pose processing and publish typed observations. Assistant combines recognized input with retained conversation context and produces a streaming response. SpeechSynthesis is a separate directed service preparing PCM; playback follows scheduled Actions.

Agents own their cognitive state and processing. Communication carries trusted source, session and causal context. Gateways validate admission and requested behavior, while Agent inboxes own pending messages.

## Scheduled behavior and direct functions

Actions represent scheduled skills such as speech playback, expression changes and NexArm movement. Channels order Actions within a task; nested wait groups synchronize that task's stages. Shared module/resource coordination prevents conflicting execution.

Tools provide direct functions such as captions, gaze, skeleton display and runtime information. A Tool's registered contract selects result feedback or completion-only behavior. Both kinds cross validated output dispatch; presentation state acceptance and physical completion are distinct boundaries.

## Host, presentation and foundations

| Owner | Responsibility |
| --- | --- |
| App | Compose capabilities and concrete behavior bindings; own voice/camera/application lifecycle and feature effects. |
| UI | Render state and collect user intent through typed operations. |
| ModelKit | Expose processing capabilities; separate management, default assembly and concrete model adapters. |
| PlatformKit | Own capture, native output, connections, device protocol and feedback. |
| Storage | Retain settings/conversation records and bounded transient audio handles. |

UI pages do not own model/device sessions. Long-lived work belongs to App lifecycle owners and runtime services. ActionRuntime and ToolRuntime are independent execution targets; Gateway depends on their contracts rather than concrete behavior domains. ModelKit and PlatformKit have no project dependencies, including Types, and own their capability inputs/outputs. App transports native device data; each calling Agent adapts it into ModelKit inputs. StorageAudio owns its own PCM contract.

## Conversation, settings and devices

Conversation records persist locally across voice sessions and restarts. New Conversation archives the current record before title generation; browsing history cannot replay behavior. Settings persist locally, credentials use the device Keychain, and App supplies provider/title/preview operations to narrow feature workflows.

The default pipeline uses local recognition, synthesis, pose and chat models. Explicit cloud configuration selects an OpenAI-compatible chat capability and sends its chat context to that provider; other perception/output remains local. Model configuration and resource acquisition share a process-wide manager.

Foreground camera perception and NexArm BLE control are implemented. Robot behavior/completion policy belongs to Actions; connection and native command/feedback belong to PlatformKit. Settings and Agent-selected movement share the same Action implementation. Autonomous camera motion belongs to the separate [Photographer proposal](Photographer-Proposal.md).

## Design and evidence entry points

The [technical design](../MobileHarness/README.md) defines dependencies and full technical flows. [Module responsibilities](../MobileHarness/README.md#part-ii--module-responsibilities) link the internal contracts. [Concepts](Concepts.md) explains terminology; [Requirements](Requirements.md) describes user outcomes. [Roadmap](Roadmap.md) lists pending directions, while [validation documents](README.md#experiments-tests-and-acceptance) record observed results.

Camera.open/close/flip Tools request the App camera owner through a typed capability after active Assistant session validation. The same foreground permission and capture lease lifecycle governs UI and Tool controls; Tool dispatch does not create a second device owner.

Cloud chat supports native function declarations from Agent JSON v5. Complete calls are resolved by the Agent and dispatched through OutputGateway; local chat remains text-only. Tool results use the existing InputGateway feedback contract, without automatic model continuation.

Photographer subscribes to VisionPerception pose observations and emits internal Robot.aim through OutputGateway. App binds the foreground BLE workflow; Actions owns aim mapping and admission, while PlatformKit supplies native command encoding. Transport acceptance does not establish physical arrival.

Tracking Tool calls publish latest targets after OutputGateway authorization. The continuous App worker holds motors1–4 through the shared ResourceCoordinator for all native writes; the publication does not acquire a second conflicting fence (ADR0126). Composition supplies Photographer construction; lifecycle owns activation and cleanup. Control-admission conflicts are recorded separately from transport recovery.

VisionPerception and Photographer share observations but have independent execution failure scopes. A rejected Robot.aim does not stop showPose. BLE connectivity and control verification are separate states; query timeout retains connectivity while quarantining control queries until App reconnects the link.

✅ Agent fault isolation: delivery failures are receipts; output execution failures are correlated results. Photographer suppresses commands while control is unavailable. Explicit stop/cancellation and invalid startup configuration remain lifecycle/assembly contracts.

Expression Actions have explicit lifetime contracts: UI.express awaits one target transition and restoration; UI.setExpression commits the persistent base. App retains one invocation-fenced override/animation waiter; UI reports transaction completion and visibility. Gaze/following remains a Tool. See [ADR0104](adr/0104-expression-perform-and-state.md).

## Local model resource separation

✅ First release bundles a versioned model catalog rather than inference artifacts; Settings requests download/removal through App into ModelKit Management. Management owns verification and safe mutation; App injects generic Storage primitives and the separate concrete ModelKitHub adapter, preserving Management’s ModelKit-only dependency. Resource admission spans quiescence/unload and disk deletion. Settings/history remain available without weights. See the [technical workflow](../MobileHarness/README.md#local-model-resource-acquisition-and-removal) and [Management current contract](../MobileHarness/ModelKit/Management/README.md#local-model-resources--current-contract).

Conversation history now retains actual native Tool declarations/calls and App-observed Gateway outcomes separately from generation state. Optional usage values retain provider/backend input/generated/total token counts. UI reads StorageChat values only; no history replay is introduced. See [ADR0106](adr/0106-conversation-tool-diagnostics.md).

✅ Local-resource refinement: compact schema-v2 repository/selection declarations replace per-file links/hashes. ModelKitHub wraps swift-huggingface 0.9.0 outside Management; App injects it. Storage-backed receipts record actual installed files/sizes. ✅ HF native background transfers preserve generations/completed files and available resume data. ❌ Full iPhone/server-resume acceptance remains pending (ADR 0108). See [ADR0105](adr/0105-local-model-resource-management.md).

Local artifact completion has two outcomes: atomic installation publication and transfer-index bookkeeping. A valid settled installation receipt remains authoritative even when task-index persistence fails. App stores the non-sensitive authoritative transfer snapshot through atomic Storage replacement with afterFirstUnlock protection; ordinary revision-checked document clients keep their existing policy.

Installation receipts derive relative paths after normalizing both the trusted directory and enumerated child URLs. This handles native /var and /private/var aliases without relaxing descendant safety checks. The exact earlier staging-prefix receipt defect has a validation-gated migration; unrelated/corrupt receipts remain failures.


✅ Nemotron multilingual recognition uses FluidAudio Core ML with a shared macOS/iOS 2240 ms artifact layout; fresh recurrent state belongs to each leased session. Management provisions resources, App/Storage publishes revision receipts, and Settings exposes incompatible-revision deletion. See ADR 0107.


✅ Native iOS background sessions now carry HF model file transfers. ModelKitHub owns persisted file plans, three active tasks/package and delegate advancement; Management preserves generations on failure/relaunch. App handles OS events and bounded preparation; Storage owns installation publication. See ADR 0108.


✅ [ADR 0109: Optional downloaded speech and modern Apple fallback](adr/0109-system-speech-fallback.md) implements persisted speech-only switching, artifact-aware Defaults facades, SpeechAnalyzer/AssetInventory ASR, Apple PCM TTS and independent energy VAD. ❌ Physical-phone end-to-end acceptance remains pending.


✅ 2026-10-03 user acceptance: phone background downloading now continues successfully and observed speed improved. ❌ Forced-quit/system termination, signed-URL expiry and large-file range-resume traces remain unverified.


✅ Apple ASR input now applies bounded backpressure instead of failing on a burst of pre-roll PCM. The real Chinese fixture test sends 137-sample packets without pacing and verifies final recognition and lease reuse. ❌ Phone ASR/TTS acceptance remains pending.


✅ Single-leaf Action failure presentation retains the captured bounded description; ModelKit capability errors preserve associated diagnostic reasons through LocalizedError. Speech SDK errors do not become business dependencies.


✅ Apple TTS resolves the production auto locale to zh-CN when text contains Han characters, otherwise en-US. Explicit locales retain their requested language/region, with zh/en script aliases normalized. Missing voices remain an explicit error with the resolved language. Consecutive real TTS integration uses auto rather than an explicit zh-CN fixture.


✅ [ADR 0110: Feature model settings and native Apple VAD](adr/0110-feature-model-settings-and-native-vad.md) groups model UI by task, splits validated custom speech choices, preserves the download backend and integrates internal native VAD. Silero or Energy supplies silence endpoint scores independently of ASR because native normal activity events were unavailable. ❌ Physical settings/voice acceptance remains pending.

Model invocation resolution failures (unknown Action/Tool alias or invalid parameters) are non-executable rejected outputs. Assistant continues the turn; OutputGateway retains them in its existing bounded execution results alongside runtime errors. Structural parsing failures and limits still terminate generation.

✅ [ADR 0111: Independent ASR/VAD selection](adr/0111-independent-asr-vad-selection.md) decouples the ASR switch from automatic Silero/Energy selection. Nemotron alone satisfies custom recognition prerequisites; Silero removal preserves ASR preference. ❌ Sustained device combination acceptance remains pending.

✅ Model source selection now automatically persists from the model section, with no network restriction toggle or explicit save action. App normalizes cellular permission to true and migrates legacy restrictions; OS permission remains authoritative. YOLO retains its fixed GitHub source. Endpoint save failure rejects download admission and preserves the draft; download queues and background transport are unchanged.

✅ ADR0103 failure isolation refinement: retained Action reports preserve later exceptions; invocation/resource rejection is call-local; Tools distinguish execution and feedback failures, with joined cooperative deadlines and task-scoped cancellation. ❌ Uncooperative handlers and physical acceptance remain outstanding.

✅ Function-defined timeout takes precedence over Runtime defaults: Action keeps request-dependent budget resolvers (including NexArm); Tool stores optional Duration in its definition/registry and @Tool factories. Unspecified Actions/Tools use30 seconds; invalid explicit declarations fail without fallback. ❌ Deadlines cannot forcibly interrupt uncooperative cleanup.

✅ [ADR 0112: Gemma CoreAI chat](adr/0112-gemma-coreai-chat.md) replaces local Qwen/MLX with Gemma 4 E2B QAT CoreAI. iOS uses pinned h18p AOT resources; old Qwen downloads are incompatible. Shared package dependencies require OS 26; CoreAI execution requires OS 27. ✅ Mac real inference, cancellation and reload passed. ❌ Sustained device acceptance remains pending.

VisionPerception stores every valid latest camera input. Inference takes the newest available input at worker start and applies expiry plus adaptive image/pose/confidence/cost/freshness cadence (initial 100ms, default bounds 0...250ms); no grayscale percentage trigger or latched request remains.

Vision timing travels with the existing replaceable UI.showPose state through OutputGateway. Native capture-callback ContinuousClock instants remain separate from media timestamps; UI receives values only and owns no model instrumentation.

✅ [ADR 0113](adr/0113-adaptive-pose-cadence.md): VisionPerception owns adaptive detection; App injects bounds, the model capability stays stateless with respect to cadence, and UI renders optional next-interval statistics through existing Tool dispatch. Native monotonic start gaps and one active operation bound scheduling without old-frame queues.

Adaptive image evidence is sampled/processed in VisionPerception using the existing immutable image contract. Inferred-frame reference and bounded pose regions survive cadence-skipped captures, while exposure/noise compensation suppresses nuisance changes. Total-latency pressure feeds scheduling; over-budget native inputs/results are rejected without publishing stale observations. Statistics remain on UI.showPose.

✅ Urgent YOLO detection now permits a zero scheduling interval. The single inference worker processes only the newest pending capture after the active call completes. Normal inference duration adds no scheduling floor; compute-dominated freshness pressure can temporarily impose a bounded cost floor. Camera close already clears skeleton and its statistics; no source-stall timer is added.

✅ UI/Camera owns PoseOverlay and display statistics. VisionPerception owns its Encodable PoseOverlayPayload; ToolPoseOverlay remains the independently validated Tool contract. App maps Tool values into UI values. UI depends only on StorageChat; AgentCore has zero project dependencies. See ADR0121.

✅ AgentCore/domain separation places pose and speech message values in Agents/Communication, application Agent names in Agents, and automatic speech guidance in Assistant. Core has zero project dependencies; scheduling completion requires explicit source. ✅ Generic message/schema registration, domain freshness policy, explicit host input adaptation and Agent-owned sample transport are implemented in stage 2. See [ADR0115](adr/0115-agentcore-domain-separation.md).

✅ Application domain contracts and identities are consolidated in Agents/Communication/AgentContracts.swift; Core/Gateway contain no speech/vision/phone contract cases. Image transport belongs to AgentCore/Input and presentation values to UI/Camera; Agent-domain speech/pose values belong to Agents/Communication; Assistant prompt policy stays in AssistantAgent.swift. Unknown/spoofed schemas reject admission. ❌ Dynamic registry reload, remote codecs and durable communication remain pending. See [ADR0116](adr/0116-generic-agent-communication.md).

SpeechPerception keeps utterance coordination in one Agent actor. VAD score adaptation, pure sample-count boundary policy, per-utterance ASR sessions and pure transcript accumulation have separate file ownership. Phase state and presentation transition together; resume and delivery recovery explicitly preserve their presentation-only observation contract.

✅ ADR0118 completes the Core boundary: host-owned concrete resource identifiers; bounded producer-owned report details and opaque error identifiers; Agent-supplied validated soft text limits with identical history preview policy. Gateway translates structural values without device semantics. No new dependency, worker or queue is introduced.

✅ Types has been removed. AgentCore/Input owns AudioInput and ImageInput; UI/Camera owns PoseOverlay; VisionPerception owns its output payload. Capability and storage types remain in their owning SDKs. See [ADR0121](adr/0121-remove-shared-types.md).

✅ [ADR0121](adr/0121-remove-shared-types.md): Types is deleted; AgentCore has zero project dependencies, UI depends only on StorageChat, and explicit Agent → Tool → App → UI adaptation preserves the pose wire format. ❌ Physical-device acceptance remains outstanding.

✅ ModelKit diagnostic cleanup: availability/errors provide typed capability outcomes and neutral diagnostic text; consumer layers own localized messages and recovery guidance. Native camera gray64 sampling remains in PlatformKit, with motion/cadence decisions in VisionPerception. ❌ Storage business/context/presentation decoupling is planned in [Storage](../MobileHarness/Storage/README.md#planned-business-decoupling); current imports are independent but semantic cleanup remains outstanding.

✅ [ADR0122](adr/0122-runtime-opaque-domain-failures.md): execution Runtime owns generic bounded resources and failure/report identifiers only; NexArm and Bluetooth producers own domain vocabulary and classification. Existing output identifiers remain unchanged. ❌ Physical robot acceptance remains outstanding.

✅ BLE writes share one PlatformKit connection-wide pacing budget; Actions keeps trajectory/completion policy and App keeps latest-intent ownership/recovery. Fixed-size transport diagnostics distinguish raw notification traffic from valid feedback. The initial rate requires physical calibration; see [ADR0123](adr/0123-nexarm-ble-shared-pacing.md).

SpeechPerception owns deterministic FOA sound direction alongside its existing VAD/ASR path. PlatformKit supplies spatial PCM only; App transports it; the Agent broadcasts typed sound.source observations through both Gateways. Optional subscribers cannot gate recognition. No Photographer behavior or UI is introduced. See [ADR0124](adr/0124-sound-source-perception.md).

Microphone readiness requires a validated/enqueued PCM callback, not only a running native capture session. PlatformKit bounds first-frame startup and joins failed spatial capture before mono retry; running streams retain their layout. App enters listening after readiness and exits it on capture failure or unexpected completion. See ADR0124's startup correction.

✅ [ADR0125](adr/0125-bluetooth-exception-recovery.md): BluetoothWorkflow unifies abnormal connected and disconnected sessions under bounded cleanup/reconnect. PlatformKit supplies facts, Actions owns behavior, and UI displays bounded diagnostic records; no old motion is replayed.

✅ ADR0127: Settings device controls enter App through UI-owned typed operations, outside InputGateway/OutputGateway. They share Actions geometry/options with Agent behavior but use send-only manual takeover without Agent resource locks or arrival waits. App cancels/joins old software writers and suppresses tracking while manual control is active; Gateway session cleanup owns Agent work only. PlatformKit native pacing and exceptional connection recovery remain shared.

## Settings audio detection (ADR0128)

✅ AudioCaptureContext is a PlatformKit-owned native fact value, independent of generic Agent transport and UI. Actual MicrophoneFrame layout establishes capture mode; runtime FOA support and mono startup fallback are separate facts. AudioDetectionSession in App/Lifecycle assembles an isolated source-only SpeechPerception with its own session/manager/Gateways and no conversation, camera or robot consumer. Existing PCM bounds/rejection and latest sound publication remain unchanged.

```mermaid
flowchart LR
    UI[Settings audio detection] --> Workflow[AppDiagnosticWorkflow: one operation and deadline monitor]
    Workflow --> Endpoint[App Lifecycle: isolated session]
    Endpoint --> Capture[PlatformKit: actual input and PCM]
    Capture --> Adapter[MediaInputAdapter / InputGateway]
    Adapter --> Speech[SpeechPerception: source-only mode]
    Speech --> DSP[Existing SoundSourceEstimator]
    DSP --> Broadcast[Bound port / OutputGateway]
    Broadcast --> Observer[App diagnostic observer]
    Observer --> Snapshot[UI display-only snapshot]
```

✅ The feature workflow depends on UI/ModelKit/PlatformKit only and invokes a whole endpoint protocol; it never constructs an Agent or Gateway. No new SDK/model dependency or AgentCore sound value is introduced. Start/stop has one operation, one monitor, no pending queue, and generation-fenced latest UI values. Stop joins hardware, Agent publication and output cleanup before replacement. Voice startup and diagnostics share explicit cleanup barriers. Direction expires at its 500 ms observation deadline; quiet/non-active states have no executable angle. Detection lasts 10 seconds after the first received frame; page departure and background cancel it.

❌ Real device FOA axes, actual acoustic accuracy, camera coexistence and native navigation/background behavior remain acceptance items.
