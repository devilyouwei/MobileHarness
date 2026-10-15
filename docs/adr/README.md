# Architecture decisions

✅ ADR0124's startup correction defines first-PCM readiness, bounded pre-admission fallback and accurate capture-failure presentation. ❌ Physical acoustic acceptance remains pending.

✅ ADR0124's native extraction correction uses CoreMedia's queried list size within a four-buffer bound and preserves retained PCM storage through synchronous reads. ❌ Physical axes/accuracy remain separate from capture acceptance.

ADRs retain the context, decision and consequences at their recorded date. Read each record's status and supersession notes; an accepted historical decision does not make its original API, model or limits current.

Current dependencies and flows belong to the [technical design](../../MobileHarness/README.md); module READMEs own current contracts. [Roadmap](../Roadmap.md) owns pending work and [validation](../README.md#experiments-tests-and-acceptance) owns experimental evidence.

✅ Decisions are indexed by their stable number below.

❌ Superseded records are historical evidence rather than current implementation requirements.

✅ [ADR0142 — Bluetooth scene lifetime and retry episodes](0142-bluetooth-scene-lifetime-and-retry-episodes.md): retain healthy background connectivity, join control suspension, reset attempts on success and grant a fresh eligible foreground episode. ❌ Physical lifecycle acceptance remains pending.

| ID | Decision |
| --- | --- |
| 0001 | [ADR 0001 原生模块化 Runtime](0001-native-modular-runtime.md) |
| 0154 | [Cohesive capability entry files](0154-cohesive-capability-entry-files.md) |
| 0153 | [Three-level capability addressing](0153-three-level-capability-addressing.md) |
| 0152 | [Business-domain capability classification](0152-business-domain-capability-classification.md) |
| 0151 | [Consolidated executable capability sources](0151-consolidated-capability-sources.md) |
| 0150 | [Unified execution lifetime](0150-unified-execution-lifetime.md) |
| 0149 | [Signal origin and returning Tool feedback](0149-signal-origin-and-tool-feedback.md) |
| 0148 | [Unified Signal contract and active architecture](0148-unified-signal-contract.md) |
| 0147 | [History deletion and result continuation](0147-history-delete-result-continuation.md) |
| 0146 | [Model resource interaction ownership](0146-model-resource-interaction-ownership.md) |
| 0145 | [History refresh Agent intent](0145-history-refresh-agent-intent.md) |
| 0144 | [Shared read-only history Tools](0144-read-only-history-tools.md) |
| 0143 | [Storage and consumer policy boundaries](0143-storage-consumer-policy-boundaries.md) |
| 0002 | [ADR 0002 模型能力与后端解耦](0002-model-capabilities.md) |
| 0003 | [ADR 0003 能力 SDK 与应用组装的编译边界](0003-capability-sdk-boundary.md) |
| 0004 | [ADR 0004 系统语音网关闭环](0004-system-voice-loop.md) |
| 0005 | [ADR 0005 按技术方案整理源码目录](0005-design-aligned-layout.md) |
| 0006 | [ADR 0006 Nemotron 流式 ASR 与模型层目录纠正](0006-nemotron-streaming-asr.md) |
| 0007 | [ADR 0007 App 使用 Nemotron ASR](0007-nemotron-app-binding.md) |
| 0008 | [ADR 0008 Silero VAD capability 与输入分段](0008-silero-vad.md) |
| 0009 | [ADR 0009 Audio8 原生 ASR adapter](0009-audio8-asr.md) |
| 0010 | [ADR 0010 默认语音切换为 Audio8 + Silero](0010-audio8-app-binding.md) |
| 0011 | [ADR 0011 有界长句识别与结束语义](0011-voice-turn-segmentation.md) |
| 0012 | [ADR 0012：实时语音预览与圆环交互](0012-live-voice-orb.md) |
| 0015 | [0015 · 分句 FunctionToken 与共享 Actions](0015-function-actions.md) |
| 0016 | [ADR 0016 — Kokoro CoreAI 独立验证](0016-kokoro-validation.md) |
| 0017 | [ADR 0017 · 新设计第一阶段：入口到 Gateway](0017-entry-gateway-migration.md) |
| 0018 | [ADR 0018 · Agent 内双协议解析与 Channel 调度](0018-agent-protocols.md) |
| 0019 | [ADR 0019 · Agent 独立 plist 配置与统一开发规范](0019-agent-configuration.md) |
| 0020 | [ADR 0020：按正式 README 对齐实现目录与命名](0020-layout-alignment.md) |
| 0021 | [ADR 0021: Remove Obsolete Voice Paths](0021-remove-obsolete-voice-paths.md) |
| 0022 | [ADR 0022: JSON Capability Configuration v2](0022-json-capability-configuration.md) |
| 0023 | [ADR 0023: Function Documentation and Model Visibility](0023-capability-doc-visibility.md) |
| 0024 | [ADR 0024: Present expressions independently from captions](0024-orb-expressions.md) |
| 0025 | [ADR 0025: One parameterized expression Action](0025-unified-expressions.md) |
| 0026 | [ADR 0026: Separate Action guidance from native tools](0026-action-only-system-context.md) |
| 0027 | [ADR 0027 — Qwen3.5 chat through MLX](0027-qwen35-mlx-chat.md) |
| 0028 | [0028 — Gateway-mediated Internal Agent Communication](0028-inter-agent-communication.md) |
| 0029 | [0029 — Exclusive Channel Ownership](0029-channel-lock.md) |
| 0030 | [0030 — Shared Model Manager](0030-shared-model-manager.md) |
| 0031 | [ADR 0031: Fixed local model resources](0031-fixed-local-model-resources.md) |
| 0032 | [ADR 0032: ModelKit management and memory policy](0032-modelkit-admission-and-memory-policy.md) |
| 0033 | [ADR 0033: ModelKit inside the project](0033-modelkit-project-boundary.md) |
| 0034 | [ADR 0034: Internal default model assembly](0034-modelkit-default-assembly.md) |
| 0035 | [ADR 0035: YOLOv8 Pose capability](0035-yolov8-pose.md) |
| 0036 | [ADR 0036: Changed camera frames → Photographer → skeleton Action](0036-photographer-pipeline.md) |
| 0037 | [ADR 0037 — Native camera frames and Vision pose inference](0037-native-vision-pose.md) |
| 0038 | [ADR 0038 — Replace YOLOv8 with YOLO26n-Pose](0038-yolo26-pose.md) |
| 0039 | [ADR 0039 — Platform Capability Domains](0039-platform-capability-domains.md) |
| 0040 | [ADR 0040 — Pure Gateway and shared perception](0040-shared-perception-and-event-routing.md) |
| 0041 | [ADR 0041 — Vision Perception Owns Skeleton Visualization](0041-vision-perception-skeleton-action.md) |
| 0042 | [ADR 0042 — ShowPose as a Completion-Only Tool](0042-show-pose-completion-tool.md) |
| 0043 | [ADR 0043 — Conversation turn presentation](0043-conversation-turn-presentation.md) |
| 0044 | [ADR 0044 — Bounded Visual Freshness](0044-visual-freshness.md) |
| 0045 | [ADR 0045 — Audio spectrum telemetry](0045-audio-spectrum-telemetry.md) |
| 0046 | [ADR 0046 — Semantic eye expressions](0046-semantic-eye-expressions.md) |
| 0047 | [ADR 0047 — Explicit input routing](0047-explicit-input-routing.md) |
| 0048 | [ADR 0048 — Direct signal admission and Agent-owned inboxes](0048-direct-signal-admission.md) |
| 0049 | [ADR 0049 — Perception-driven eye gaze](0049-perception-eye-gaze.md) |
| 0050 | [0050 — Default Kokoro synthesis](0050-default-kokoro-synthesis.md) |
| 0051 | [ADR 0051: OpenAI-compatible cloud chat](0051-openai-compatible-chat.md) |
| 0052 | [0052 — Local Kokoro Core ML bilingual synthesis](0052-kokoro-coreml-bilingual.md) |
| 0053 | [ADR 0053: Settings and immediate chat selection](0053-settings-live-chat.md) |
| 0055 | [ADR 0055 — Directed synthesis Agent and transient audio handles](0055-synthesis-agent-audio-handles.md) |
| 0056 | [ADR 0056 — Shared Storage core and PCM adapter](0056-storage-audio-migration.md) |
| 0057 | [ADR 0057: Local settings persistence and cache synchronization](0057-local-settings-storage.md) |
| 0058 | [0058 — Replace default Kokoro with MOSS-TTS-Nano](0058-moss-tts-nano.md) |
| 0059 | [ADR 0059 — Structured wait groups for Action scheduling](0059-structured-wait-scheduling.md) |
| 0060 | [ADR 0060 — Persistent conversation history and explicit conversation boundaries](0060-persistent-conversation-history.md) |
| 0061 | [ADR 0061 — Channel-grouped model catalogs and code-owned internal behavior](0061-agent-json-v5.md) |
| 0062 | [ADR 0062 — Optional chat output-token budgets](0062-default-chat-output-budget.md) |
| 0063 | [ADR 0063 — Consolidate behavior runtimes, Agent source ownership and App views](0063-module-directory-consolidation.md) |
| 0064 | [ADR 0064 — Separate App ownership and UI](0064-app-ui-boundaries.md) |
| 0065 | [ADR 0065 — Action implementation contracts and execution diagnostics](0065-action-runtime-contracts.md) |
| 0066 | [ADR 0066 — Action terminal feedback and resource leases](0066-action-results-resource-leases.md) |
| 0067 | [ADR 0067 — Domain-owned behavior definitions and capability assembly](0067-domain-owned-behavior-assembly.md) |
| 0068 | [ADR 0068 — Canonical Action entry points](0068-canonical-action-entrypoints.md) |
| 0069 | [ADR 0069 — Storage core and domain directories](0069-storage-core-domain-layout.md) |
| 0070 | [ADR 0070 — NexArm supervised USB Action](0070-nexarm-usb-diagnostic.md) |
| 0071 | [ADR 0071 — Foreground iPhone NexArm BLE](0071-nexarm-iphone-ble.md) |
| 0072 | [ADR 0072 — Bounded NexArm entertainment skills](0072-nexarm-entertainment-skills.md) |
| 0073 | [ADR 0073 — Peripheral detail controls](0073-peripheral-detail-controls.md) |
| 0074 | [ADR 0074 — NexArm live joystick control](0074-nexarm-live-jog.md) |
| 0075 | [0075 — Fixed NexArm choreography](0075-nexarm-fixed-choreography.md) |
| 0076 | [0076 — NexArm controller preset transport](0076-nexarm-controller-preset-transport.md) |
| 0077 | [0077 — Calibrated physical pose choreography](0077-nexarm-calibrated-pose-choreography.md) |
| 0078 | [0078 — Shared NexArm controller and physical validation](0078-nexarm-shared-physical-validation.md) |
| 0079 | [0079 — Continuous NexArm manual jog](0079-nexarm-smooth-jog.md) |
| 0080 | [0080 — Independent NexArm motion results](0080-nexarm-independent-motion-results.md) |
| 0081 | [0081 — Settings immediate test control](0081-settings-immediate-test-control.md) |
| 0082 | [0082 — NexArm channel observation and host watchdogs](0082-nexarm-observation-watchdogs.md) |
| 0083 | [0083 — Unified Action execution presentation](0083-action-execution-presentation.md) |
| 0084 | [ADR 0084 — LLM output buffering](0084-llm-output-buffering.md) |
| 0085 | [ADR 0085 — Reply-owned speech audio](0085-reply-owned-speech-audio.md) |
| 0086 | [ADR 0086 — Domain-owned Action display metadata](0086-action-display-metadata.md) |
| 0087 | [ADR 0087 — Producer-owned speech deadline](0087-speech-producer-deadline.md) |
| 0088 | [0088 — Settings-matched NexArm Cartesian playback](0088-nexarm-settings-matched-playback.md) |
| 0089 | [ADR 0089 — NexArm performance completion covers arm axes](0089-nexarm-arm-completion-scope.md) |
| 0090 | [ADR 0090 — NexArm gestures and home never address the gripper](0090-nexarm-arm-only-motion-packets.md) |
| 0091 | [0091 — NexArm motor-scoped feedback execution](0091-nexarm-motor-scoped-feedback.md) |
| 0092 | [0092 — Atomic actions and composed results](0092-atomic-actions-and-composed-results.md) |
| 0093 | [ADR0093 — NexArm PlatformKit and Action boundary](0093-nexarm-platform-action-boundary.md) |
| 0094 | [ADR0094 — Arrival profiles, dynamic execution budgets and behavior macros](0094-arrival-profiles-and-behavior-macros.md) |
| 0095 | [ADR0095 — Remove retired device and behavior code](0095-remove-retired-device-and-behavior-code.md) |
| 0096 | [ADR 0096 — Behavior-owned execution contracts](0096-behavior-owned-contracts.md) |
| 0097 | [ADR 0097 — Opaque source identity for audio storage](0097-storage-audio-opaque-owner.md) |
| 0098 | [ADR 0098 — Independent runtime, workflow and audio boundaries](0098-independent-runtime-workflow-audio-boundaries.md) |
| 0099 | [ADR0099 — Shared Types grouped by category](0099-shared-types-layout.md) |

| 0100 | [ADR0100 — Camera control Tools reuse the App owner](0100-camera-control-tools.md) |

| 0101 | [ADR0101 — Cloud native Tool calls](0101-cloud-native-tool-calls.md) |

✅ [0102 — Photographer aim on shared pose](0102-photographer-aim.md) keeps aim business policy in Actions and independent ToolRuntime dispatch. ❌ Physical tracking acceptance remains pending.

✅ [0103 — Agent failure isolation](0103-agent-failure-isolation.md) defines nonfatal messaging/execution outcomes and Photographer offline suppression. ❌ Sustained device acceptance remains pending.

✅ ADR0102 now includes incremental pose tracking and adjacent-target speed selection in Actions; existing Agent isolation remains governed by ADR0103.

✅ [0104 — Expression Perform and Set contracts](0104-expression-perform-and-state.md) separates awaited finite expression performance from persistent base state. ❌ Physical animation acceptance remains pending.

❌ [0105 — Local model resource management](0105-local-model-resource-management.md) records first-release Management-owned downloads/deletion with App-injected Storage and metadata-only packaging; device acceptance remains pending.

- [0106: Conversation Tool diagnostics and token usage](0106-conversation-tool-diagnostics.md) — durable native calls, actual execution outcomes, optional usage and bounded journal serialization.

Model-resource history: ADR0006/0007/0016/0031/0034/0050/0052 preserve earlier model selection/provisioning decisions; ADR0058 owns current MOSS selection and ADR0105 owns current source metadata, installation/removal and background limitations. Historical bundle-weight statements are not current contracts.

✅ ADR0105 refinements document selected regular-file Hub acquisition and distinguish committed model installation from transfer-index bookkeeping failures. ❌ Live iPhone download/lock-state acceptance remains separate.

✅ [0107: Shared multilingual Nemotron Core ML ASR](0107-nemotron-coreml-multilingual.md).

✅ [0108: Durable background model downloads](0108-background-model-downloads.md).


✅ [ADR 0109: Optional downloaded speech and modern Apple fallback](0109-system-speech-fallback.md) implements persisted speech-only switching, artifact-aware Defaults facades, SpeechAnalyzer/AssetInventory ASR, Apple PCM TTS and independent energy VAD. ❌ Physical-phone end-to-end acceptance remains pending.


✅ [ADR 0110: Feature model settings and native Apple VAD](0110-feature-model-settings-and-native-vad.md) groups model UI by task, splits validated custom speech choices, preserves the download backend and integrates internal native VAD. Energy remains for silence endpoint timing because native normal activity events were unavailable. ❌ Physical settings/voice acceptance remains pending.

✅ ADR0103 now includes nonterminal unknown model calls and parameter rejection in shared execution outcomes. ❌ Real-provider acceptance remains pending.

✅ [ADR 0111: Independent ASR/VAD selection](0111-independent-asr-vad-selection.md) decouples the ASR switch from automatic Silero/Energy selection. Nemotron alone satisfies custom recognition prerequisites; Silero removal preserves ASR preference. ❌ Sustained device combination acceptance remains pending.

✅ ADR0103 failure isolation refinement: retained Action reports preserve later exceptions; invocation/resource rejection is call-local; Tools distinguish execution and feedback failures, with joined cooperative deadlines and task-scoped cancellation. ❌ Uncooperative handlers and physical acceptance remain outstanding.

✅ Function-defined timeout takes precedence over Runtime defaults: Action keeps request-dependent budget resolvers (including NexArm); Tool stores optional Duration in its definition/registry and @Tool factories. Unspecified Actions/Tools use30 seconds; invalid explicit declarations fail without fallback. ❌ Deadlines cannot forcibly interrupt uncooperative cleanup.

✅ [ADR 0112: Gemma CoreAI chat](0112-gemma-coreai-chat.md) replaces local Qwen/MLX with Gemma 4 E2B QAT CoreAI. iOS uses pinned h18p AOT resources; old Qwen downloads are incompatible. Shared package dependencies require OS 26; CoreAI execution requires OS 27. ✅ Mac real inference, cancellation and reload passed. ❌ Sustained device acceptance remains pending.

✅ [ADR 0113: Adaptive latest-frame pose detection](0113-adaptive-pose-cadence.md) documents Agent-owned image/pose/confidence/cost/freshness scheduling and existing Tool statistics. ❌ Physical-phone calibration remains pending.

- [0114 — Visual presentation values outside AgentCore](0114-vision-presentation-values.md)

- [0115 — AgentCore and domain separation, stage 1](0115-agentcore-domain-separation.md)

- [0116 — Generic Agent communication and coherent ownership](0116-generic-agent-communication.md)

- ✅ [0117: SpeechPerception file ownership](0117-speech-perception-file-ownership.md) separates pure boundary/text policy from model sessions and centralized Agent transitions; ❌ sustained device acceptance remains pending.

- [0118 — Generic resource/results and Agent-owned text segmentation](0118-core-residual-policy-separation.md)

- [0119 — SDK-owned values and caller adaptation](0119-sdk-owned-values-and-caller-adaptation.md): remove SDK Types dependencies and place model preparation in the actual caller.

- [0120 — Agent-domain value ownership](0120-agent-domain-value-ownership.md): keep business speech/pose messages in Agents; Types retains cross-target transport/presentation.

- [0121 — Remove shared Types](0121-remove-shared-types.md): input, Agent payload and UI value ownership.

- [0122 — Runtime opaque domain failures](0122-runtime-opaque-domain-failures.md): producer-owned classification and generic resources.

- [0123 — Shared NexArm BLE write pacing](0123-nexarm-ble-shared-pacing.md): connection-wide admission and transport diagnostics.

- [0124 — FOA sound-source perception and optional broadcasting](0124-sound-source-perception.md)

- [0125 — Bounded Bluetooth exception recovery and diagnostics](0125-bluetooth-exception-recovery.md): App recovery policy, joined cleanup and per-device memory cache.

✅ [ADR0126](0126-aim-worker-resource-ownership.md): latest aim intents and continuous worker resource lifetime; explicit admission diagnostics.

- [0127 — Settings manual robot takeover](0127-settings-manual-robot-takeover.md): reuse Action recipes with send-only playback, immediate replacement and no Agent resource lock.

- [0128 — Settings audio detection](0128-settings-audio-detection.md): isolated diagnostic capture, source-only SpeechPerception, native capture facts and joined cleanup.

✅ ADR0128: Settings preset/reset submission returns immediately; a cancellable background worker uses the shared Actions segment-feedback executor. Replacement joins software cleanup without waiting for arrival. ❌ Physical takeover/rhythm acceptance remains pending.

✅ [ADR0129](0129-bluetooth-session-isolation.md): independent Bluetooth recovery and Agent scheduling; device failures retain normal Action/Tool results and accepted queues.

## Passive BLE connection — ADR0130

✅ Native connection/subscription completion makes Settings controls available immediately. App performs no connection pose/version/IK probe, stationary validation or indication movement. It listens to unsolicited position packets and publishes measured state; refresh reads the latest received packet only. Feedback silence remains visible but does not disable manual commands, disconnect or start recovery. Native write/connection failures remain explicit. Actions uses passive BLE compatibility for this App connection; recipe IK resolution is deferred to an explicit preset request, not connection verification. Manual jog can start from the existing configured reference when no sample has arrived; that reference is not measured telemetry. Segment arrival observation and cancellable replacement remain in Actions/App.

❌ Physical feedback cadence, preset IK availability and sustained manual takeover require real-device acceptance. Passive connection does not establish physical clearance or target arrival.

- ✅ [ADR0131 — Independent execution/native ownership](0131-independent-bluetooth-diagnostics.md): execution and recovery isolation remains current; its exception-history scheme is superseded by ADR0134.
- ✅ [ADR0132 — Execution error semantics](0132-execution-error-semantics.md): producer codes, root causes and worker provenance remain current; device event writers are superseded by ADR0134.

- ✅ [ADR0133 — Motion admission and terminal reports](0133-motion-admission-and-terminal-reports.md): demand-driven Actions preparation, capability-aware bounded BLE admission, independent native interruption facts and preserved terminal execution reports. ❌ Real-device acceptance remains pending.

✅ ADR0134: Bluetooth exception history is removed at SDK/App/UI layers. Latest native connection, communication issue and recovery state alone appear in Settings; healthy snapshots/new connections replace prior faults. ADR0138 uses one row to connect while unconnected or open detail when already connected; connection success stays on the list, disconnect appears only when connected, and remembered devices remain forgettable; an already-open disconnected detail disables actions/motor gestures. Execution results/home issues and bounded automatic recovery remain independently owned. ❌ Physical BLE/navigation/touch acceptance remains pending.

- ✅ [ADR0134 — Bluetooth current state and navigation](0134-bluetooth-current-state-and-navigation.md): removes SDK/App/UI incident history, displays latest native state and disables disconnected controls; its automatic connection/navigation policy is superseded by ADR0136. Execution and recovery remain independent. ❌ Physical acceptance remains pending.

- ✅ [ADR0135 — NexArm final tracking count](0135-nexarm-aim-final-count.md): the last near-target count remains pending until native admission, then planned motion converges without a fractional tail. Physical arrival and Tool publication remain distinct; supervised serial fixtures exercise Settings and Agent boundaries.

- ✅ [ADR0136 — Explicit Bluetooth connection and native navigation](0136-bluetooth-explicit-navigation.md): historical separate connection buttons/dimmed links superseded by ADR0138; stable one-level native back navigation and a combined yellow warning with the current red native error. ❌ Physical swipe/layout acceptance remains pending.

- ✅ [ADR0137 — Ordinary NexArm home](0137-nexarm-ordinary-home.md): restores legacy query-free ordinary reset, keeps tracking rest separate, preserves gripper exclusion and explicit single-motor software homes. ❌ Restored physical posture acceptance remains pending.

- ✅ [ADR0138 — Compact Bluetooth device rows](0138-compact-bluetooth-device-list.md): row-tap connection, later connected-tap detail, connected-only Disconnect, saved-device Forget, correct grouping and persisted default reconnection. ❌ Phone layout/gesture acceptance remains pending.

- ✅ [ADR0139 — Tracking freshness and Assistant preemption](0139-tracking-freshness-and-assistant-preemption.md): one-second usable-pose expiry and host-configured joined writer takeover, preserving queued Actions. ❌ Physical interruption/timing acceptance remains pending.


- ✅ [ADR0140 — Cancellation-safe resource cleanup](0140-cancellation-safe-resource-cleanup.md): coordinator-owned bounded stop/join acknowledgment survives caller cancellation; confirmed cleanup does not become faulted or grant a cancelled requester a lease. ❌ Physical stop verification remains pending.


- ✅ [ADR0141 — Resource control ownership](0141-resource-control-ownership.md): unlocked/locked(owner), one actual holding authority, revocable execution permits and automatic late cleanup release; no faulted/recover latch. ❌ Physical stop/native isolation acceptance remains pending.

✅ [ADR0148 — Unified Signal contract](0148-unified-signal-contract.md): active architecture location, canonical AgentInput envelope, common Signal/execution rules before six scenario examples, with origin, feedback/effect diagrams and consolidated implementation gaps; no runtime change.

✅ ADR0149 implements origin admission and owner-fenced Tool feedback. ❌ Action/activity causal roots and typed host controls remain pending.

Historical [ADR0155 — Explicit Action serialization identity](0155-explicit-action-serialization-identity.md): superseded by ADR0213; preserved as original decision evidence.

❌ Three-level runtime paths and unified Action/Tool definitions are not completed by this stage.

✅ [ADR0156 — Three-level capability addresses](0156-three-level-capability-addresses.md): explicit fields and Agent configuration v6 bindings implemented; resource scopes preserved. ❌ Unified definitions/adapters and compatibility removal remain pending.

✅ [ADR0157 — Canonical executable definitions](0157-canonical-executable-definitions.md): completes shared definition/outcome/execution, protocol projections, scheduled native routing, typed feedback and compatibility retirement. Remaining work is broader Agent-driven input/feature migration and physical acceptance.

✅ [ADR0158 — Unified Action authoring](0158-unified-action-authoring.md): one @Action attribute for all capabilities; model context supplies text actions and request tools supplies native declarations. Text tags and native events retain distinct ActionCall/ToolCall transports.

✅ [ADR0159 — Protocol-independent invocations](0159-protocol-independent-action-invocations.md) removed native-only business signatures. ADR0161 completes the boundary with one FunctionInput/context/handler and @Action metadata; ActionInvocation remains a Gateway scheduling adapter. Differences remain in registration, model transport/parsing, runtime admission and feedback.

✅ [ADR0160 — Callable functions and protocol bindings](0160-callable-functions-and-protocol-bindings.md) separates pure callable implementation from host registration/runtime protocol policy.

✅ [ADR0161 — Gateway execution and isolated function contracts](0161-gateway-execution-and-function-contracts.md).

✅ ADR0162: invocation-local failures preserve structured reports and terminal causes across both call protocols; explicit cancellation and admission scopes remain unchanged. See [decision](0162-invocation-failure-isolation.md).

✅ [ADR0163 — Typed history and feedback causality](0163-typed-history-and-feedback-causality.md): typed history.intent/1 and explicit Action/activity causal feedback. Unified lifecycle/capability fact Signals, archive/title, resource/device Agent routes and bounded model continuation stay separate stages.

✅ [ADR0164 — Typed Assistant host control](0164-typed-assistant-host-control.md): assistant.control/1 replaces the host cancellation string; runtime.event permission is removed from Assistant. ❌ Unified lifecycle/capability facts remain pending.

✅ [ADR0165 — Agent-selected archive and title](0165-agent-history-archive-and-title.md): deterministic history archive/title sequencing and Gateway effects replace direct workflow mutations. ❌ Conversational mutations and general model continuation remain pending.

- [ADR0166 — Agent-routed model resource commands](0166-agent-model-resource-commands.md): bounded native admission/cancel/remove through both Gateways.

- [ADR0167 — Agent-routed speech model binding](0167-agent-speech-model-binding.md): explicit application failure and durable preference retry.

- [ADR0168 — Agent-owned resource preference transactions](0168-agent-resource-preferences.md): two-call source/binding sequence and durable preference ownership.

- [ADR0169 — Agent-routed resource inventory](0169-agent-resource-inventory.md): bounded query results and shared installed prerequisites.

- [ADR0170 — resource refresh presentation](0170-agent-resource-refresh-presentation.md): ✅ Agent-selected, revision-fenced resource snapshot/query-failure presentation; other settings paths remain staged.

- [ADR0171 — root resource observations](0171-root-resource-state-observations.md): ✅ Sequenced native invalidations and page-independent sampled presentation; native push/shared state remain outstanding.

- [ADR0172 — resource command failures](0172-agent-resource-command-failures.md): ✅ Agent-selected operation-error presentation; preference/transport routes remain staged.

- [ADR0173 — resource preference failures](0173-agent-resource-preference-failures.md): ✅ Agent-selected notices/error presentation, exact failure codes and per-request call bounds; host fallback remains staged.

- [ADR0174 — Resource host failure Signals](0174-resource-host-failure-signals.md): ✅ Recoverable transport diagnostics through Agent-selected presentation; infrastructure fallback remains explicit.

- [ADR0175 — Agent-routed provider model discovery](0175-agent-provider-model-discovery.md): ✅ Credential-free discovery intents and bounded canonical queries; transactions/presentation remain pending.

- [ADR0176 — Provider configuration transactions](0176-agent-provider-configuration-transactions.md): ✅ Agent-selected restore/save, private credentials/results and Actions-owned apply/rollback. Registered provider UI effects are implemented in ADR0177; native acceptance remains pending.

- [ADR0177 — Provider presentation and policy](0177-agent-provider-presentation-and-policy.md): passive provider form, Actions eligibility and registered result/error commitment.
- [ADR0178 — Bounded native continuation](0178-bounded-native-result-continuation.md): correlated native results, four model rounds, actual error data and exact request history.
- [ADR0179 — Device/navigation/environment](0179-typed-device-navigation-environment.md): shared manual/model functions, sequenced root facts, independent manual terminal results and zero-dependency UI values.

- [ADR0180 — Memory and Photographer business services](0180-memory-photographer-service-organization.md): canonical Memory naming and focused Photographer/Memory business components; implemented; checks/device build passed, Simulator dependency blocked.

- [ADR0181 — Photographer camera control](0181-photographer-camera-control.md): camera ownership, bounded root service and authorized model delegation; checks/device build passed, Simulator dependency blocked.


✅ [ApplicationControl service organization](0182-application-control-service-organization.md): ADR0182 implements canonical role-directory, identity and host-transport migration; existing business behavior retained. Validation is recorded separately.

✅ [ADR0183](0183-generation-round-observations.md): implemented Action/Tool split, registered observations and full-round result merge; physical/model acceptance remains pending.

✅ [ADR0184](0184-assistant-photo-observation.md): Assistant photo Action, screenshot presentation and multimodal observation loop.

✅ [ADR0185](0185-photo-save-and-ignore.md): Agent-driven current-photo save to system Photos and ignore from UI/dialogue; physical acceptance remains pending.

✅ [ADR0186](0186-camera-lens-switch-lifetime.md): healthy lens input replacement completes independently of joined perception retirement; physical latency acceptance remains pending.

✅ [ADR0187 — Agent composition and ReACT](0187-agent-composition-and-react.md): implemented abstraction and contracts; business roles retained, phase-two delegation remains separate.

✅ Phase two specialist ownership implementation: [ADR0188](0188-specialist-task-ownership.md). Implemented; real-model/native-UI/physical-device acceptance pending.

✅ [Shared Agent source hierarchy - ADR0189](0189-agent-support-hierarchy.md): implemented; repository checks and unsigned iOS device build passed.

✅ [ADR0190 — SpeechPerception listening authority and one-way publication](0190-assistant-listening-and-one-way-publication.md): resident perception authority, fixed listening Action, unacknowledged publication and recoverable speech errors. ❌ Physical acoustic acceptance pending.

- [ADR0212: Assistant Skills and task modes](0212-assistant-skills-task-modes.md) — ❌ pending.

✅ [ADR0213 — Channel-owned Action ordering](0213-channel-owned-action-ordering.md): definition serialization keys removed; retain task-local Channel/wait ordering and explicit resource conflict/takeover outcomes.


- ✅ [ADR0214 — Result-driven ReACT](0214-result-driven-react.md): actual business output and failures replace registration-selected continuation; automated checks and generic iOS-device build verified, Simulator dependency blocked.

- ✅ [ADR0215 — One pan/tilt packet per tracking target](0215-nexarm-aim-one-shot.md): one synchronous motors 1/4 packet per admitted target, bounded lead/dead zone and native-admission commit; main framework and lifecycle contracts retained. Physical acceptance limits remain in the decision.
