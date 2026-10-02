# Archived documentation notes

These notes were accumulated in project entry points and public architecture/index pages. They describe their original context and may repeat or be superseded by dated ADRs. They are historical source material, not current capabilities or contracts. Current entries are listed in [the documentation index](README.md).

## Notes from the project README

✅ Settings includes optional cloud text chat configuration for HTTPS Base URL, API key and model through the same ModelKit capability as local Qwen. See [cloud adapter](../MobileHarness/ModelKit/Language/LLM/OpenAI/README.md). ❌ Live-provider acceptance remains pending.



✅ Speech synthesis now runs in a dedicated Agent receiving directed text requests. Scheduled speech consumes transient audio IDs; cache limits and lifetimes are described in ADR 0055. ❌ Physical-device validation of this revision remains pending.

✅ Speech output now goes directly from validated Action admission to scheduled audio-ID playback. The output/session owner releases unused audio after failures and cancellation; no preparation stage remains. ❌ Physical-device acceptance is pending.

Local user settings now use Storage-backed cached persistence in the application sandbox; credentials remain in Keychain. Optional repository-local runtime files belong under ignored `.local/`. See [Storage](../MobileHarness/Storage/README.md).


✅ Function Token output supports nested `<wait>...</wait>` execution groups. Wait joins earlier parent work and all internal Actions while preserving ordinary Channel concurrency; it does not block unrelated Agent tasks. See [scheduling](../MobileHarness/Gateway/Output/Scheduling/README.md). ❌ Physical-device acceptance of the new coordination behavior is pending.

✅ Settings → 对话历史 stores actual user inputs, raw model text, exact request context and failures locally. Current context retains the latest ten completed rounds; Start New archives it and generates a title. See [conversation history](../MobileHarness/UI/Settings/README.md). ❌ Live-model title quality and device acceptance remain pending.

## Action runtime migration

✅ Stage 2 adds bounded Action execution feedback and shared resource ownership, with camera capture as the first production integration. See [ADR 0066](adr/0066-action-results-resource-leases.md) and [roadmap](Roadmap.md). ❌ Other hardware mappings, durable delivery and physical-device acceptance remain pending.

## Behavior module ownership

✅ Actions/Tools now own explicit behavior catalogs; App binds typed capabilities through the independently tested BehaviorAssembly target. See [ADR 0067](adr/0067-domain-owned-behavior-assembly.md). ❌ New native capabilities can still require App adaptation.

## NexArm diagnostic

✅ An opt-in macOS USB [NexArm Action](../MobileHarness/Actions/NexArm/README.md) now supports supervised hardware validation through the gateways. ✅ Assistant declares `shakeBase(cycles: 1...3)` for supervised Mac USB sweeps; the hardware test supplies the real binding and deterministic model output. ✅ iPhone settings and foreground BLE binding are implemented. ❌ TCP, unattended robot safety and full physical acceptance remain pending.

✅ iPhone Settings → 蓝牙设备 now scans NexArm, verifies/connects, remembers one device, disconnects and forgets. Return to conversation to request “让底座左右晃动一次”; supported posture and finite-motion bounds still apply. [BLE lifecycle and limits](../MobileHarness/PlatformKit/Connectivity/NexArm/README.md) distinguish implementation/tests from physical acceptance.

✅ Action implementations now group related entries, with registration, types and services in domain Support directories. See the [Action authoring standard](../MobileHarness/Actions/README.md); public behavior and runtime contracts are unchanged.

✅ NexArm gesture definitions and completion execution now belong to Actions; PlatformKit remains the independent connection/protocol SDK. See [ADR0093](adr/0093-nexarm-platform-action-boundary.md) for the enforced source and target boundary.

✅ The PlatformKit responsibility audit also moved manual motion/reset policy to Actions and presentation policy to App. The [NexArm Actions README](../MobileHarness/Actions/NexArm/README.md) now provides the consolidated English current-state design and diagrams; repository instructions explicitly enforce directory ownership.

✅ Action/Tool entries use attached metadata macros; NexArm completion now prioritizes fresh arrival and uses centralized motor profiles and dynamic deadlines. See [ADR0094](adr/0094-arrival-profiles-and-behavior-macros.md).

## Notes from the documentation index

✅ [ADR 0057](adr/0057-local-settings-storage.md) records local document cache/persistence synchronization and user-settings migration. ❌ Cross-device synchronization remains deferred.


✅ [MOSS validation](Moss-Validation.md) records replacement-model setup and evidence; [ADR 0058](adr/0058-moss-tts-nano.md) records the default change. ❌ Device acceptance is separate from build and Mac checks.

✅ ADR 0053 records optional cloud credentials and endpoint defaults. ❌ Live provider acceptance remains pending.

✅ Architecture and Roadmap describe the persistent conversation-history page, which supersedes the standalone raw-output test. It records real Assistant traffic; historical parser preview never executes Actions. ❌ Its preview does not establish physical-device or scheduler acceptance.


✅ [ADR 0059](adr/0059-structured-wait-scheduling.md) records nested wait synchronization, task-local queues and the removal of implicit main. ❌ Live-model and device acceptance remain separate from compile/test evidence.

✅ Current generation/output/routing diagrams include typed wait boundaries. The [historical technical baseline](Tech_Design.md) and ADR 0015 explicitly point to the replacement scheduling rules; their original algorithms remain historical evidence. The Channel lock section is a future ownership proposal, not current wait behavior.

✅ [ADR 0060](adr/0060-persistent-conversation-history.md) records durable current/past conversations, ten-round context and archived-title generation. ❌ Earlier in-memory conversations are not recoverable.

✅ [ADR 0061](adr/0061-agent-json-v5.md) defines the current JSON v5 model catalog and code-owned internal permissions. Older ADRs describe historical schemas where marked superseded. ❌ Full native Tool schemas/streaming remain future work.

✅ [ADR 0062](adr/0062-default-chat-output-budget.md) documents optional output budgets and default-provider behavior.

✅ [模块目录整合](adr/0063-module-directory-consolidation.md) 记录 Runtime 子目录、Agents/Core 编译边界及当时的 App/Views 归属；页面后续迁到独立 UI 模块，见 ADR 0064。

- [ADR 0064 — App and UI boundaries](adr/0064-app-ui-boundaries.md): explicit composition, independently compiled pages and application workflows.

✅ [ADR 0065](adr/0065-action-runtime-contracts.md) and [Actions/Runtime](../MobileHarness/Actions/Runtime/README.md) record the implemented Action contract stage and its limits. ❌ Ongoing activity owners, persistent resource enforcement and execution deadlines remain future work.

## Action runtime stage 2

✅ [ADR 0066](adr/0066-action-results-resource-leases.md) supersedes the stage-1 future-work entries for Action terminal feedback and resource arbitration. Detailed contracts live in Gateway/Output/Results and Resources. ❌ Durable feedback, generic activity management, audio/robot migration and hardware acceptance remain outstanding.

## Behavior module assembly

✅ [ADR 0067](adr/0067-domain-owned-behavior-assembly.md) and the BehaviorAssembly README describe ownership and extension rules. ❌ Automatic discovery and universal device capabilities are not supplied.

## Canonical Action entry audit

✅ [ADR 0068](adr/0068-canonical-action-entrypoints.md) records the Action implementation audit and typed speech capability migration. ❌ Physical-device acceptance remains outstanding.

## Storage core/domain layout

✅ [ADR 0069](adr/0069-storage-core-domain-layout.md) records the Storage core/domain split and no-data-migration guarantee.

❌ Image/video/semantic-memory storage and cross-device synchronization remain planned.

✅ [ADR 0070](adr/0070-nexarm-usb-diagnostic.md) records the opt-in USB wrist Action and its production limitations. ❌ Wireless/iPhone robot acceptance remains pending.

✅ ADR 0070 also records the supervised Assistant base Action and explicit unavailable iPhone binding. ❌ Wireless and unattended robot acceptance remain outstanding.

✅ [ADR 0071](adr/0071-nexarm-iphone-ble.md) documents iPhone BLE settings, bounded transport, shared Action binding and foreground cancellation. ❌ Physical acceptance and emergency-stop guarantees remain distinct from implementation.

✅ ADR 0071 distinguishes NexArm BLE connection from control readiness and documents manual read-only revalidation. ❌ Persistent AT32 version readout and physical iPhone acceptance remain open.

✅ ADR 0071 records the user-requested one-time reset/ID5 connection indication and its separate write-ACK/physical-feedback contract. ❌ Hardware acceptance remains pending.

✅ Revised ADR 0071 records physical USB/BLE evidence and explicit NexArm 1.0.2 compatibility for missing AT32 version, with truthful presentation and ID5 ±8° connection feedback. ❌ iPhone motion acceptance remains pending.

✅ ADR 0071 now records user-confirmed iPhone conversation control, firmware-independent BLE protocol validation, broad BLE discovery and read-only foreground recovery. ❌ Updated physical discovery/lock-screen UX acceptance remains pending.

## NexArm entertainment skills (2026-09-30)

✅ [ADR 0072](adr/0072-nexarm-entertainment-skills.md) records finite NexArm entertainment skills, typed host bindings and cancellation/failure limits. ❌ Full physical sequence acceptance remains pending.

## Peripheral detail controls

✅ [ADR 0073](adr/0073-peripheral-detail-controls.md) records Bluetooth peripheral details, shared manual-motion admission and measured telemetry. ❌ Physical six-motor acceptance remains pending.

✅ ADR 0073 now distinguishes unconfirmed motion from transport failure and documents read-only recovery without forced reconnection. ❌ Physical recovery acceptance remains pending.

✅ ADR 0073 now covers complete Bluetooth discovery/forget cleanup and one-shot read-only recovery after native transport loss. ❌ System accessory unpairing is outside the App's CoreBluetooth controls.

✅ [ADR 0074 — NexArm live jog](adr/0074-nexarm-live-jog.md) separates streaming manual intents from completion-based presets and records reset preemption. ❌ Physical acceptance pending.

✅ [Fixed NexArm choreography](adr/0075-nexarm-fixed-choreography.md) records absolute gesture targets, synchronous servo packets and feedback/cancellation semantics. ❌ Physical acceptance remains pending.

✅ [NexArm preset transport compatibility](adr/0076-nexarm-controller-preset-transport.md) records the replacement of raw servo broadcasts and clarified reset/feedback semantics. ❌ Physical confirmation remains pending.

✅ [Calibrated NexArm pose choreography](adr/0077-nexarm-calibrated-pose-choreography.md) distinguishes physical pose from example encoder counts and unifies phone performance transport. ❌ Full physical acceptance remains pending.

✅ [NexArm USB physical acceptance](NexArm_Physical_Acceptance.md) records seven real-arm results, failed diagnoses and reproducible shared-controller testing. [ADR0078](adr/0078-nexarm-shared-physical-validation.md) owns the resulting contract. ❌ USB does not establish BLE timing.

✅ 2026-09-30: shared NexArm jog planner uses bounded acceleration/jerk, finite look-ahead, 30 ms scheduling and native servo position writes without per-write pose queries. Tests cover smoothing, duplicate suppression, six-axis streaming, congestion and reset preemption. See [ADR 0079](adr/0079-nexarm-smooth-jog.md). ❌ BLE physical cadence/visual smoothness require phone acceptance.

✅ [ADR 0080](adr/0080-nexarm-independent-motion-results.md): explicit preset admission no longer depends on previous completion/recovery feedback. New actions retain their own completion checks. ❌ Physical failure recovery acceptance remains pending.

✅ Tilt return repair keeps ready height240mm while preserving arm-relative yaw±12°/roll±40° and unchanged arrival thresholds. Both complete USB sequences passed; see [physical acceptance](NexArm_Physical_Acceptance.md). ❌ Phone BLE acceptance remains pending.

✅ [ADR0081](adr/0081-settings-immediate-test-control.md) separates immediate preemptible settings tests from unchanged completion-based channel actions. ❌ Settings send status does not assert physical completion.

✅ [ADR0082](adr/0082-nexarm-observation-watchdogs.md) adds continuous pose reception, notification-first channel completion, limited query fallback and independent silence/total deadlines. Settings live tests remain unchanged. ❌ Device-side watchdog and action-ID completion require firmware support.

✅ ADR0082 clarifies whole-action budget composition after isolated USB dance reproduction: sum per-segment allowances without extending the fixed deadline during playback.

✅ NexArm physical acceptance records a full isolated USB channel run after2026093015: all7 presets/50 segments completed observed arrival and home return in68.073s. BLE and repeated-cycle acceptance remain separate.

✅ [ADR0083](adr/0083-action-execution-presentation.md) documents unified channel execution observation and frontend presentation, including bounds, cancellation semantics and lifecycle ownership.

✅ ADR0083 also records internal-action visibility filtering and native Liquid Glass presentation. NexArm argument validation errors are identified separately from device-connectivity failures.

✅ [ADR 0084](adr/0084-llm-output-buffering.md) documents removal of the LLM pending-event count limit. ❌ Phone replay acceptance remains pending.

✅ NexArm head preparation now matches the other presets’ intermediate arrival contract; regression tests retain strict final-home verification. Actual phone measurements for the reported timeout remain unavailable.

✅ [NexArm physical acceptance](NexArm_Physical_Acceptance.md) now includes reproduced head no-motion failure, a controlled handoff experiment, and successful nod/shake closed-loop USB evidence. ❌ USB results do not substitute for phone BLE conversation acceptance.

✅ [Action authoring](../MobileHarness/Actions/README.md) now specifies cohesive entry files and non-callable Support directories. This is source organization only; runtime contracts and historical ADRs remain unchanged.

✅ [ADR 0085](adr/0085-reply-owned-speech-audio.md) records reply-owned speech cache retention and post-Action cleanup. ❌ Physical-device long-sequence acceptance remains pending.

✅ ADR 0070 records removal of the unused diagnostic Action while retaining direct device tests and production Action coverage.

- ✅ [ADR 0086](adr/0086-action-display-metadata.md) removes centralized Action UI maps through domain-owned metadata and generic state rendering.

✅ ADR 0082 now records the all-segment nominal-duration gate and celebration/dance regression coverage. ❌ The reported motor2 oscillation remains pending physical iPhone BLE acceptance.

✅ [ADR 0087](adr/0087-speech-producer-deadline.md) documents producer-owned PCM waits and regression coverage for delayed synthesis. ❌ Physical playback acceptance remains pending.

✅ [ADR0088](adr/0088-nexarm-settings-matched-playback.md) records Settings-matched Cartesian Channel playback and final-home completion. The user reports the phone symptom resolved. [Physical acceptance](NexArm_Physical_Acceptance.md) records five supervised USB dance comparisons: intermediate waits alone reproduced motor2 jitter and timeout; queries or extra frames alone did not. ❌ Underlying servo holding-loop causes, isolated celebration and endurance remain unverified.

✅ TTS documentation audit (2026-09-30): Agent admission/FIFO, Speech.speak scheduling, producer-owned waits, hardware completion and per-reply PCM cleanup are aligned across module READMEs and the technical plan. Historical MOSS measurements are preserved with the old read deadline explicitly labeled historical. ❌ These documentation corrections do not establish the cause of reported repetition or abnormal speech.

✅ [ADR0089](adr/0089-nexarm-arm-completion-scope.md) documents arm-only performance completion after reproducing a claw-offset-induced timeout. ❌ This is not gripper calibration or grasp verification.

✅ [ADR0090 — Arm-only motion packets](adr/0090-nexarm-arm-only-motion-packets.md) documents gripper exclusion from all arm motion and home writes. ❌ BLE endurance remains pending.

## NexArm feedback execution — 2026-10-01

✅ ADR0091 records motor-scoped feedback execution, superseding the motion progression portions of ADR0088/0090 while preserving gripper exclusion.

❌ Sustained real-device acceptance remains pending.

## Atomic composition — ADR0092

✅ ADR0092 documents atomic motor outcomes and Action composition, superseding failure-propagation portions of ADR0091.

❌ Sustained real-device acceptance and durable result delivery remain outstanding.

✅ [ADR0093](adr/0093-nexarm-platform-action-boundary.md) defines the NexArm foundational protocol SDK versus Action behavior boundary.

✅ [ADR0094](adr/0094-arrival-profiles-and-behavior-macros.md) records fresh-arrival completion, measured profiles, dynamic budgets and Action/Tool macros. Bounded hardware evidence lives in [measurements](measurements/README.md).

✅ [ADR0095](adr/0095-remove-retired-device-and-behavior-code.md) records removal of unused device placeholders and isolation of retired Action diagnostics.

- [Behavior-owned execution contracts](adr/0096-behavior-owned-contracts.md): module ownership and upstream translation.

## Notes from the public architecture

Default speech now uses local MOSS-TTS-Nano Core ML (beta) behind the same capability and audio-cache boundary. Kokoro is no longer selected or packaged, following repeated device crashes. [ADR 0058](adr/0058-moss-tts-nano.md) records the replacement; device acceptance remains pending.

Cloud settings allow blank credentials and an omitted endpoint (official OpenAI URL fallback). Registration remains local; authentication and provider compatibility errors surface during discovery or generation. See the updated [ADR 0053](adr/0053-settings-live-chat.md).

StorageAudio production PCM cache defaults to 8 MiB per handle (32 live handles; 256 MiB aggregate PCM ceiling, allocated on demand). This matches the synthesis Agent’s per-request output limit and accommodates approximately 43.7 seconds of MOSS 48 kHz mono Float32 audio. Overflow remains explicit; see ADR 0058.

Settings includes [conversation history](../MobileHarness/UI/Settings/README.md) for actual Assistant exchanges. It preserves original user text, received model fragments, exact request context and error status in local durable storage. Current conversation context uses its latest ten completed rounds across voice sessions and App restarts. Start New archives it, creates an empty context and generates an archived title; pending titles can be retried. Stored markup is inspected without execution. This replaces the former single-turn raw-output test; it helps inspect wait failures but does not prove scheduler timing. See [ADR 0060](adr/0060-persistent-conversation-history.md).


Action scheduling now uses task-local nested wait groups: each wait joins its parent's prefix, preserves Channel FIFO/concurrency internally, and releases the parent's suffix only after closure and completion. Equal Channel names no longer imply a shared cross-task FIFO; device-module exclusion remains process-wide. [ADR 0059](adr/0059-structured-wait-scheduling.md) records the protocol and migration. Tools and speech synthesis prefetch remain outside these Action groups.

## Agent configuration and internal behavior

✅ JSON v5 declares model-callable Actions grouped by Channel, native function Tools and unchanged communication policy. Fixed speech/caption/transcript/gaze/overlay behaviors and their permissions are code-owned. Model parsers cannot resolve internal operations; all outputs still cross OutputGateway. See [ADR 0061](adr/0061-agent-json-v5.md). ❌ Full JSON Schema and provider-native Tool deltas remain unimplemented.

ChatRequest output budgets are optional: normal Assistant calls omit max_tokens for provider defaults; local Qwen bounds generation by remaining context. Historical explicit budgets remain readable. Parser and execution capacity limits still apply.

## Source ownership

Actions and Tools each include their Runtime subdirectory in a single compilation target. Shared contracts live in Agents/Core but retain the independent AgentCore target to preserve acyclic StorageAudio/Gateway dependencies; see [ADR 0063](adr/0063-module-directory-consolidation.md). SwiftUI pages, page state and interaction interfaces now live in the sibling UI module under [ADR 0064](adr/0064-app-ui-boundaries.md). Runtime flow and behavior are unchanged.

## App and UI boundary

AppAssembly owns application composition. App/Composition builds the graph, Lifecycle owns voice/camera scopes and cleanup, Workflows coordinates settings/history/diagnostic operations, and Adapters connects validated effects to native devices and presentation state. UI is an independent sibling target containing pages, observable state and operation protocols. It imports shared record values only; pages do not own application runtimes, stores, model sessions or players. See [ADR 0064](adr/0064-app-ui-boundaries.md).

The current lifecycle owners are VoiceSessionCoordinator, CameraCoordinator and VisionSession. ApplicationRuntime creates Assistant with the shared journal; CurrentChatCapability resolves the selected chat binding for conversation and title requests. Both speech and chat diagnostic execution belong to AppWorkflows. UI may own short-lived rendering/load tasks or await an injected diagnostic operation; long-lived voice/camera ownership stays in App. Directory/file inventories live in the [App](../MobileHarness/App/README.md) and [UI](../MobileHarness/UI/README.md) READMEs.

## Action implementation contracts

✅ App now validates Action implementation definitions against assembled Agent capabilities before producers start. Invocation derives from one envelope; scheduler admission assigns an execution ID. Shared argument readers and separated runtime/scheduling/domain errors support consistent Actions. A bounded, payload-free diagnostic ring records execution phases and conservative effect status; it does not alter scheduling or produce Agent feedback. See [ADR 0065](adr/0065-action-runtime-contracts.md).

❌ Continuous activity owners, persistent resource leases, execution/cleanup deadlines and full business Action style migration remain outstanding. UI state acceptance still does not await animation, and speech still awaits playback completion.

## Action feedback and resource ownership

✅ [ADR 0066](adr/0066-action-results-resource-leases.md) adds correlated ActionResult feedback through InputGateway and a single process-wide resource authority shared by declared Action/Tool/host paths. Results describe the handler completion boundary; ongoing ActivityEvent is separate. Message retry never repeats effects. Ownership binds Agent incarnation/session; group takeover gates, stops and joins before granting, with faulted gates on uncertain cleanup. Camera capture uses a renewable lease.

❌ Generic activity management, other device resource migration, durable delivery, physical watchdogs and real-device acceptance remain pending; these replace the corresponding stage-1 future-work items above.

## Behavior assembly ownership

✅ [ADR 0067](adr/0067-domain-owned-behavior-assembly.md) moves concrete behavior definitions into Action/Tool domain modules. A pure BehaviorAssembly target under App/Composition/Behaviors constructs and validates both registries; App supplies typed effects and retains device/runtime lifetime. Agent permissions remain independent. ❌ This does not provide dynamic discovery or new device capabilities.

## Canonical Action entry audit

✅ [ADR 0068](adr/0068-canonical-action-entrypoints.md) completes the current UI/Speech entry standard. Speech transport validation belongs to Actions; its host capability receives a typed UUID. Playback cleanup is joined before failure returns. ❌ No new device/animation functionality is implied.

## Storage core/domain layout

✅ Storage now separates generic mechanisms in its root from Audio and Chat domains. StorageChat depends on Storage; UI imports only shared chat values. Source relocation preserves journal data and runtime semantics. See [ADR 0069](adr/0069-storage-core-domain-layout.md).

❌ Image/video/semantic-memory storage and cross-device synchronization remain planned.

## NexArm supervised diagnostic

An opt-in NexArm Action now delegates through a typed host binding to an actor-owned PlatformKit USB controller on macOS. The hardware test composes both gateways and the Action scheduler with Assistant JSON declaring the bounded base Action. Completion is controller-reported position convergence; uncertain effects block subsequent motion. The built-in domain catalog requires a typed base callback; Mac test composition binds USB; iPhone composition now binds BluetoothWorkflow (ADR 0071). This is a supervised diagnostic exception, not unattended robot control. See [ADR 0070](adr/0070-nexarm-usb-diagnostic.md).

## Foreground NexArm Bluetooth

Settings now discovers supported NexArm devices, verifies firmware, remembers one selected device and exposes explicit disconnect/forget. AppAssembly retains one workflow/connection across page navigation and injects its motion handler into the existing Action module. CoreBluetooth stays in PlatformKit; UI contains only state and control interfaces. Both Gateways and the domain Action remain on the conversation execution path. Foreground loss cancels subsequent legs and closes the connection without pretending to stop an already committed motor command. [ADR 0071](adr/0071-nexarm-iphone-ble.md) defines bounds and acceptance limits.

Bluetooth disconnect cleanup is scoped to robot work. The global voice/session barrier is used only before explicitly arming a replacement connection; see ADR 0071. Vision consumes terminal Action receipts before image-only validation.

NexArm readiness verifies firmware once per live controller/connection, permits at most four read-only queries for explicitly missing AT32 information, and never retries a transport failure or motion. BLE exchange deadline is five seconds based on measured device latency; see ADR 0071.

NexArm native connection and control readiness are separate. An explicit missing AT32 version retains the link but rejects motor Actions; a user-requested verification may establish readiness on that same connection after the requested indication described below. Rejected Actions do not replay. Other verification failures still close the link (ADR 0071).

Explicit NexArm connection now includes user-requested physical feedback after verification: one arm reset and a bounded ID5 gesture. AppWorkflows owns the indication task and readiness transition; PlatformKit separates ATT write acknowledgment from sampled physical convergence. Cancellation joins the committed leg and prevents remaining commands (ADR 0071).

Current NexArm BLE policy supersedes the earlier missing-version-only blocking behavior: App selects the explicit NexArm 1.0.2 compatibility profile, requires valid stationary telemetry for the known missing-AT32 response, and reports the unavailable version honestly. Reset and ID5 ±8°/center feedback must complete before ready. Controller default remains strict; no motion/transport retry or persistent firmware attestation is added. See revised ADR 0071.

Current Bluetooth UX supersedes the previous version-based compatibility gate: normal App connections use service/pose/gesture validation without querying firmware. Discovery lists BLE advertisements regardless of name/service (128-row bound), prioritizing NexArm names. Root-owned foreground recovery reconnects the saved verified UUID once per activation, performs read-only validation and never replays motions. Manual disconnect/forget and uncertainty disable persisted recovery. The user has confirmed the iPhone conversation-control path; the new scan/recovery UX remains to be accepted on device. See revised ADR 0071.

## NexArm entertainment skills (2026-09-30)

NexArm entertainment Actions use one typed host binding and the existing root-owned BLE motion lifecycle. PlatformKit owns bounded preset keyframes; neither model output nor Actions can supply arbitrary servo trajectories. All gestures share NexArm exclusion and cancel without replay. See [ADR 0072](adr/0072-nexarm-entertainment-skills.md).

## Peripheral detail controls

✅ 蓝牙外设 connects to a detail page for sampled arm state, existing gesture presets, explicit reset and six bounded motor sliders. UI owns presentation only; root AppWorkflows owns manual admission and shares the controller/motion lifecycle with conversation Actions. Explicit host device controls do not synthesize Agent messages. See [ADR 0073](adr/0073-peripheral-detail-controls.md). ❌ Six-motor physical acceptance remains pending.

## Unconfirmed motion is separate from connection failure

✅ NexArm motion uncertainty no longer discards a live Bluetooth controller. The workflow releases busy admission and retains the failure result; refresh or a new explicit request uses bounded read-only stationary validation before new movement. Actual transport loss still closes control. No motion replay is introduced. See the recovery amendment in [ADR 0073](adr/0073-peripheral-detail-controls.md).

## Bluetooth discovery and recovery ownership

✅ Native discovery drops unnamed devices before retaining them, and connection clears scan results while retaining only its selected link. App forget joins disconnection and clears native, persisted and presented device state. Gesture completion is separate from validated connectivity. A transport timeout still fences the old request channel, then App may make one read-only reconnect attempt without replay. See the current lifecycle amendment in [ADR 0073](adr/0073-peripheral-detail-controls.md).

## Manual servo stream versus preset completion

✅ Six spring-return velocity controls use a root-owned latest-intent worker and a separate BLE no-response session. Manual input does not wait for arrival/telemetry and reset can preempt preset output. Preset Play retains the existing completion contract. Read observations, commanded estimates and local transport admission remain distinct. See [ADR 0074](adr/0074-nexarm-live-jog.md).

✅ NexArm entertainment Actions now execute fixed absolute preparation/body/ending poses using synchronized six-servo targets and native acceleration. Every waypoint is observed; final home requires stable telemetry. Explicit reset retains priority over playback. See [ADR 0075](adr/0075-nexarm-fixed-choreography.md). ❌ Physical choreography acceptance remains pending.

✅ [ADR0076](adr/0076-nexarm-controller-preset-transport.md) replaces unverified raw broadcast preset writes with the established CMD51 controller path. Six target writes overlap motion; whole-pose feedback still determines completion. Reset does not require a completion reply.

✅ [ADR0077](adr/0077-nexarm-calibrated-pose-choreography.md) replaces nominal encoder-based performance admission/completion with fixed Cartesian poses through the working whole-arm CMD50 path. Phone base sway now uses the same performance engine. ❌ New full motion sequences await physical acceptance.

✅ Mac USB and iPhone BLE share `NexArmWritableLink` and the exact same preset controller. Native absolute CMD8 replaces host-measured increment compensation; all seven presets now have USB physical feedback acceptance. See [ADR0078](adr/0078-nexarm-shared-physical-validation.md) and the [acceptance record](NexArm_Physical_Acceptance.md). ❌ BLE timing/visual quality remain separate.

✅ 2026-09-30: shared NexArm jog planner uses bounded acceleration/jerk, finite look-ahead, 30 ms scheduling and native servo position writes without per-write pose queries. Tests cover smoothing, duplicate suppression, six-axis streaming, congestion and reset preemption. See [ADR 0079](adr/0079-nexarm-smooth-jog.md). ❌ BLE physical cadence/visual smoothness require phone acceptance.

✅ [ADR 0080](adr/0080-nexarm-independent-motion-results.md): explicit preset admission no longer depends on previous completion/recovery feedback. New actions retain their own completion checks. ❌ Physical failure recovery acceptance remains pending.

✅ [ADR0081](adr/0081-settings-immediate-test-control.md) separates immediate preemptible settings tests from unchanged completion-based channel actions. ❌ Settings send status does not assert physical completion.

✅ [ADR0082](adr/0082-nexarm-observation-watchdogs.md) adds continuous pose reception, notification-first channel completion, limited query fallback and independent silence/total deadlines. Settings live tests remain unchanged. ❌ Device-side watchdog and action-ID completion require firmware support.

✅ Dance timeout correction: the fixed overall channel deadline sums all per-segment motion and settling budgets, preserving2s feedback silence and per-segment limits. Previously one shared3s margin truncated a healthy multi-frame dance before its ending. Settings playback and pose tolerances are unchanged.


## Unified Action execution presentation

✅ [ADR0083](adr/0083-action-execution-presentation.md) adds scheduler-owned execution observation independent of Agent result delivery. AppWorkflows maps bounded full snapshots to UI-only channel summaries and recent history. All active work remains tracked; terminal retention is100 records. Cancellation pending remains visible until handler cleanup joins. ❌ Device-specific progress and durable history are not provided.

✅ Action display includes every scheduled Action. Fixed internal UI updates use immediate Tools outside the observation stream. Invalid Action arguments are distinguished from physical-device failures; the execution panel uses native Liquid Glass on supported iOS versions.

### Action / Tool presentation boundary correction

✅ Every scheduled Action is observable; there are no module/source filters. Fixed UI updates are completion-only Tools with explicit append/replacement semantics; model expression remains an Action. Failure descriptions come from the thrown error, bounded in the scheduler snapshot, while machine codes remain metadata. See [ADR0083](adr/0083-action-execution-presentation.md). ❌ Native model Tool output and physical-phone visual acceptance remain separate follow-up work.

### Single-motor head gestures

✅ Nod and head shake use a calibrated-home preparation and native motor4/5 trajectories. Channel arrival checks encoders with the same freshness/deadline policy; Settings remains send-only with bounded nominal targets. The shared transport admits only the new bounded motor command. ❌ Physical acceptance of these added gestures remains pending. See [NexArm](../MobileHarness/PlatformKit/Connectivity/NexArm/README.md).

✅ LLM output buffering is decoupled from consumer speed: cloud/local chat retain pending events without a count cap and drain them in order after generation. Generation/response bounds and downstream execution limits remain. See [ADR 0084](adr/0084-llm-output-buffering.md).

Head gestures cross from Cartesian trajectory control to native motor control. The shared NexArm controller keeps observing while requiring a fresh arrival sample after the ready trajectory duration before that handoff; strict final arrival and bounded watchdogs remain. A distinct ready target precedes native writes so the ending home is a new Cartesian request. See the [physical acceptance evidence](NexArm_Physical_Acceptance.md) and [controller contract](../MobileHarness/PlatformKit/Connectivity/NexArm/README.md).

## Cohesive Action files (2026-09-30)

✅ Related short Action entries now share domain files. Non-callable registrations, capability interfaces, types and resource services live in domain Support subdirectories; shared infrastructure remains in Actions/Runtime. Public symbols, paths, permissions, completion and scheduling contracts remain unchanged. The [Action standard](../MobileHarness/Actions/README.md) owns source-layout rules.

❌ This source reorganization adds no device behavior or runtime contract.

✅ Speech PCM lifetime now follows its originating reply: no queued/ready cache expiry. After Gateway joins all reply Actions, App clears remaining source/input audio; interruption closes session audio. Played segments release immediately. See [ADR 0085](adr/0085-reply-owned-speech-audio.md).

✅ The unused NexArm wrist diagnostic Action and test-only Agent have been removed. Hardware diagnostics use direct controller tests; the eight production NexArm Actions retain their existing Agent/Gateway path. Runtime ActionDiagnostics remains scheduler-owned execution history, not a callable diagnostic Action. See ADR 0070.

## Domain-owned Action display metadata

✅ ActionDefinition owns a validated human-readable name, copied into shared execution records at admission. Root Workflow forwards scheduler snapshots; UI computes generic statuses/styles and preserves exact Channel names. Neither Workflow nor UI enumerates concrete Actions. Observation is separate from Agent outputs and ActionResult delivery. See [ADR 0086](adr/0086-action-display-metadata.md).

❌ This does not add localization resources, durable audit delivery or per-device progress.

## Tool source organization

✅ Tool entries are grouped by domain, with non-entry registration/interfaces/types/policy under domain Support and the built-in catalog under Runtime. Tools remains one independent target depending only on AgentCore; direct returning/completion execution, cancellation and InputGateway feedback contracts are unchanged. ❌ This source migration adds no scheduler, live health probe or native model Tool transport.

✅ Conversation NexArm completion now requires a fresh stable arrival after each segment’s nominal trajectory duration, extending the head-only handoff protection to whole-arm gestures. Observation and watchdogs remain active throughout. See the [controller contract](adr/0082-nexarm-observation-watchdogs.md) and ADR 0082. ❌ Reported celebration/dance motor2 oscillation requires physical BLE acceptance.

Speech playback now waits for synthesis progress without an independent PCM read timeout. The synthesis Agent retains its 60-second execution deadline; failures, cancellation, capacity bounds and hardware drain watchdogs remain explicit. See [ADR 0087](adr/0087-speech-producer-deadline.md).

✅ NexArm Cartesian conversation gestures now share Settings frame generation and nominal playback timing, then observe final home before releasing whole-Action ownership. Intermediate waypoint arrival is no longer part of their completion contract; head gestures retain calibrated per-segment control. See [ADR0088](adr/0088-nexarm-settings-matched-playback.md). ❌ Physical jitter acceptance is pending.

NexArm performance completion now verifies the arm axes independently of gripper position: XYZ/pitch/roll and motors1–5 retain their existing convergence and stability requirements. Generic arrival tracking remains strict by default; outbound gesture packets are unchanged. See [ADR0089](adr/0089-nexarm-arm-completion-scope.md).

### NexArm arm-only output (ADR0090)

All arm gestures and home/reset exclude the gripper at packet level, not only arrival checks. PlatformKit prepares a bounded connection-local read-only IK table and compiles shared Settings/Channel geometry into synchronous writes explicitly listing IDs1–5. AppWorkflows prepares this capability before live admission and preserves motor6 in command estimates. Explicit manual gripper jogging remains independent. There is no six-axis fallback; see [ADR0090](adr/0090-nexarm-arm-only-motion-packets.md).

## NexArm feedback execution — 2026-10-01

✅ NexArm motion now uses motor-scoped plans with one controller owner, common Settings/Channel execution, feedback-driven advancement, bounded skip-and-report for missed segments and connection-level feedback watchdog priority. Action definitions remain dependency-injected; PlatformKit does not import AgentCore. See ADR0091.

❌ Sustained real-device acceptance remains pending.

## Atomic composition — ADR0092

✅ ADR0092 separates Action execution termination from success: structured child reports, resource-union composition and Channel failure isolation. Device feedback loss is a leaf outcome; cancellation is an explicit control path.

❌ Sustained real-device acceptance and durable result delivery remain outstanding.

✅ NexArm business gestures, localized names, motion completion and error-collection policies belong to Actions/NexArm/Support. PlatformKit is the foundational connection/protocol/native-command SDK with no business dependencies. Settings and Channel consume the same injected Action controller through AppWorkflows. See [ADR0093](adr/0093-nexarm-platform-action-boundary.md).

✅ PlatformKit audit further separates native capabilities from policy: Actions owns manual jog/reset behavior; AppWorkflows owns Bluetooth presentation of structured transport failures and device ordering; App adapters own preview layout. Audio/vision acquisition and conversion remain foundational capabilities. See the current [NexArm technical design](../MobileHarness/Actions/NexArm/README.md).


## Arrival completion and behavior metadata (ADR0094)

Actions own per-motor arrival profiles and dynamic execution budgets. Arrival succeeds on fresh in-tolerance feedback; only off-target failure uses stability. Runtime deadlines cancel and join handlers, preserving child reports. `@Action`/`@Tool` generate explicit definition factories through the isolated BehaviorDefinitions compiler plugin; App injection and Agent JSON permissions are unchanged. See [ADR0094](adr/0094-arrival-profiles-and-behavior-macros.md).

The cleanup in [ADR0095](adr/0095-remove-retired-device-and-behavior-code.md) removes unused generic device placeholders and isolates historical polling diagnostics in Tests. PlatformKit/Core currently contains documentation only; actual authorization remains in the concrete adapters.

Actions and Tools now own Contracts directories and have no AgentCore dependency. Gateway translates Agent intents and delivery results; App projects UI display data and adapts stored audio. See [ADR0096](adr/0096-behavior-owned-contracts.md).

## Audio storage identity boundary — ADR0097

✅ ADR0097 removed AgentCore from audio storage. ADR0098 subsequently moved PCM values to Types; StorageAudio now depends only on Storage and Types, and consumers pass opaque source strings instead of AgentID. Source/session/input authorization and cancellation behavior are preserved. See [ADR0097](adr/0097-storage-audio-opaque-owner.md).

✅ Shared PCM values are now extracted; new physical-device acceptance remains outside this migration.

## Independent dependency boundaries — ADR0098 (2026-10-02)

✅ Gateway depends only on AgentCore/ActionRuntime/ToolRuntime; behavior assembly and Agent permission coverage are separate. Six feature workflow targets replace the broad workflow implementation target, with injected provider/title/preview operations. Types is shared by model/device/storage SDKs, and Lifecycle receives role-specific services and Agent factories. Existing business/runtime algorithms are preserved. Current direct dependencies are in MobileHarness/README.md. See [ADR0098](adr/0098-independent-runtime-workflow-audio-boundaries.md).

❌ Real-provider/device acceptance and multi-window coordination remain separate; no phone installation is part of this refactor.

## Shared Types layout — ADR0099 (2026-10-02)

Types is the independent shared-value target, organized by category under Types/Audio. ModelKit, PlatformKit and StorageAudio consume Types; audio algorithms, validation and compatibility exports are unchanged. Image values currently remain in ModelKit/Core; future shared categories require concrete consumers. Current Tools has no PlatformKit dependency; a future device Tool domain may consume PlatformKit without adding a dependency to ToolRuntime. The technical plan now includes the current compilation dependency diagram. See [ADR0099](adr/0099-shared-types-layout.md).
