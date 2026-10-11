# Project documentation

✅ [ADR0124](adr/0124-sound-source-perception.md) records bounded microphone first-frame startup, pre-admission mono fallback and capture-failure presentation. ❌ Physical acoustic and coexistence acceptance remains separate from builds and synthetic tests.

✅ [iPhone 17 Pro spatial-capture investigation](Validation-History.md#2026-10-05--open-issue-supported-iphone-foa-capture-falls-back-to-mono): device logs confirm native 48 kHz/four-channel Float32 ACN/SN3D delivery; failure was AudioBufferList extraction. Build `2026100505` queries the actual list size within a fixed four-buffer bound, passed native regressions/full checks and was installed/launched. The user confirmed direction angles and uncertain/quiet states during Settings detection. ❌ Physical axes/precision and coexistence acceptance remain pending.

## Requirements and public explanations

| Document | Purpose |
| --- | --- |
| [Project README](../README.md) | Project introduction, Agent-loop concepts and getting started. |
| [Requirements](Requirements.md) | Product goals, user scenarios, expected behavior and scope boundaries. |
| [Concepts](Concepts.md) | Biological analogy and vocabulary for Agents, capabilities, communication, Actions and Tools. |
| [Architecture](Architecture.md) | Public explanation of the current system and ownership boundaries. |
| [Platform boundaries](Platform-Boundaries.md) | Foreground/device capabilities and physical-control constraints. |
| [Roadmap](Roadmap.md) | Current delivery priorities, unimplemented directions and acceptance work. |
| [History mutation continuation](adr/0147-history-delete-result-continuation.md) | ✅ Confirmed deletion, correlated feedback and cancellation cleanup; model continuation pending. |
| [Model resource UI boundary](adr/0146-model-resource-interaction-ownership.md) | ✅ Resource interaction ownership moved to feature workflow; commands, preferences, inventory and presentation now route through ResourceManagement (ADR0166–0171). |
| [History refresh intent](adr/0145-history-refresh-agent-intent.md) | ✅ Deterministic memory Agent and scoped presentation; archive/title also implemented in ADR0165. |
| [Shared history Tools](adr/0144-read-only-history-tools.md) | ✅ Read-only model-callable history previews; History refresh/deletion/archive/title are implemented; model continuation remains pending. |
| [Storage consumer policy](adr/0143-storage-consumer-policy-boundaries.md) | ✅ First Agent-driven migration stage: context, title and producer-error ownership. |
| [Photographer proposal](Photographer-Proposal.md) | Proposed camera composition/motion behavior; not an implemented Agent. |
| [Resource 状态计划](Resource-State-Plan.md) | ❌ 当前 UI/App/设备状态的快速存取与 Agent 上下文接入计划；lock 兜底另行处理。 |

## Current technical design

The [19-document Agents design audit](Validation-History.md#2026-10-11--agents-technical-design-alignment) records role/shared/Core diagram, table and contract checks against the latest source and prompt resources.

The [role-owned prompt validation](Validation-History.md#2026-10-11--role-owned-prompt-templates-and-shared-function-token-guidance) records the separate role and Function Token resources, strict rendering and final packaging checks.

The [OpenAI backpressure validation](Validation-History.md#2026-10-11--openai-128-event-backpressure) records the 128-event session, ordered suspending emission and cancellation/cleanup checks.

The [overall accuracy and redundancy review](Validation-History.md#2026-10-11--overall-design-accuracy-and-redundancy-review) preserves the original organization while reconciling current flows, source contracts and duplicate explanations.

The [108-document source README audit](Validation-History.md#2026-10-10--full-source-readme-audit) records current design reconciliation, static verification and the complete inspection register. [Documentation history](Documentation-History.md#2026-10-10--source-readme-technical-design-reconciliation) records evidence relocation.

The [expanded overall-design verification](Validation-History.md#2026-10-10--expanded-overall-technical-design) records the restored system-level contracts, complete production target map and current diagram/link checks after the overall README expansion.

The [original-structure restoration](Validation-History.md#2026-10-11--original-overall-design-structure-restored) records restoration of the original three Parts, subsection order and three-layer architecture, with targeted current-content corrections.


| Location | Owns |
| --- | --- |
| [MobileHarness/README.md](../MobileHarness/README.md) | Single overall technical design: Agent-driven architecture, module ownership, directory/target dependencies, Signal and execution contracts, and complete cross-module flows. |
| `MobileHarness/<module>/README.md` | Current module responsibilities, interfaces, algorithms, limits and lifecycle/failure contracts. |
| Nested module READMEs | Domain-specific values, callable entries, adapters and processing policies. |

## Experiments, tests and acceptance

| Evidence | Scope |
| --- | --- |
| [Validation history](Validation-History.md) | Dated repository, build, packaging and installation observations. |
| [Voice acceptance guide](Voice.md) | Reproduction steps and full conversation acceptance criteria. |
| [MOSS validation](Moss-Validation.md) | Synthesis experiments, timings and playback investigations. |
| [Nemotron validation](Nemotron-Validation.md) / [Silero validation](Silero-Validation.md) | Recognition/VAD experiments and their recorded environments. |
| [NexArm physical acceptance](NexArm_Physical_Acceptance.md) | Supervised physical trials and failure investigations. |
| [Measurements](measurements/README.md) | Raw retained device measurement data and interpretation constraints. |
| [Kokoro validation](Kokoro-Validation.md) / [Audio8 validation](Audio8-Validation.md) / [Bootstrap validation](Bootstrap-Validation.md) | Historical model/bootstrap experiments; not evidence for the current default pipeline. |

## Decisions and history

| Record | Purpose |
| --- | --- |
| [ADR index](adr/README.md) | Dated decisions, rationale and supersession. |
| [Change log](Change-Log.md) | Dated project/documentation changes. |
| [Milestone history](Milestone-History.md) | Earlier implementation milestones and their contemporary evidence. |
| [Documentation history](Documentation-History.md) | Archived notes formerly accumulated in current entry pages. |
| [Historical technical baseline](Tech_Design.md) | Original Markdown design, retained as historical source material. |
| [Original Word design](Technical_Design.docx) | Preserved original design source. |
| [License notices](licenses/README.md) | Third-party notices and redistribution information. |

## Documentation ownership

Requirements describe desired outcomes; concepts explain vocabulary; public architecture describes current collaboration. Current technical contracts live in source READMEs. Roadmap describes pending work rather than the history of every change.

Put changes/rationale in the change log or an ADR. Put experimental measurements, test results and installation observations in evidence documents with date, environment, method and scope. Earlier results remain historical after a model, implementation or device change. Preserve original reports and raw data; link them rather than copying measurements into current design pages.

✅ Requirements, concepts, current design, proposals, evidence, history and notices have separate entry points.

✅ Validation history records verified iPhone installation of ADR0140/ADR0141 in build 2026100503. ❌ Foreground startup and physical acceptance remain unverified; automatic launch was denied while the phone was locked.

❌ Undelivered proposals and unrecorded acceptance are not current implementation claims.

✅ [ADR0142](adr/0142-bluetooth-scene-lifetime-and-retry-episodes.md) records healthy background connection retention and independent foreground retry episodes. Validation history confirms iPhone installation and fresh launch of build 2026100601. ❌ Physical suspension/late-callback acceptance remains pending.

✅ [ADR0100](adr/0100-camera-control-tools.md) records foreground Camera Tool ownership, completion and lease policy; native Tool transport and physical camera acceptance remain pending.

✅ [ADR0103](adr/0103-agent-failure-isolation.md) defines Agent isolation, bounded delivery/execution outcomes and Photographer offline suppression. ❌ Physical fault acceptance remains pending.

✅ Latest main-sh incremental Photographer tracking is integrated through [ADR0102](adr/0102-photographer-aim.md), preserving main’s module boundaries and failure isolation. ❌ Physical smoothness acceptance remains pending.

✅ [ADR0104](adr/0104-expression-perform-and-state.md) documents finite expression and persistent base-state contracts; physical visual acceptance remains on the Roadmap.

✅ Conversation Tool history and usage contract: [ADR0106](adr/0106-conversation-tool-diagnostics.md); physical-provider/UI acceptance remains outstanding.

✅ Audio8 validation remains a historical record; its unused provisioning profile/wrapper was removed during local model cleanup. Mac real-model test fixtures remain retained; shared production source ownership is documented in Resources/Models.

✅ Model-resource documentation audit (2026-10-03): current READMEs describe source declarations, metadata-only builds, sandbox receipts, explicit voice warmup and HF foreground/ZIP background limits. Older model packaging/default-provider ADRs and validation reports are explicitly historical and point to ADR0105/current module contracts; original Technical_Design.docx remains unchanged.

✅ Architecture, Roadmap and ADR0105 distinguish successful model publication from task-record persistence failure and describe the targeted Storage policy. ❌ Phone incident attribution is not claimed from isolated regression tests.

✅ [Shared multilingual Nemotron Core ML runtime](adr/0107-nemotron-coreml-multilingual.md).


✅ [ADR 0109: Optional downloaded speech and modern Apple fallback](adr/0109-system-speech-fallback.md) implements persisted speech-only switching, artifact-aware Defaults facades, SpeechAnalyzer/AssetInventory ASR, Apple PCM TTS and independent energy VAD. ❌ Physical-phone end-to-end acceptance remains pending.


✅ [ADR 0110: Feature model settings and native Apple VAD](adr/0110-feature-model-settings-and-native-vad.md) groups model UI by task, splits validated custom speech choices, preserves the download backend and integrates internal native VAD. Energy remains for silence endpoint timing because native normal activity events were unavailable. ❌ Physical settings/voice acceptance remains pending.

✅ Architecture and Roadmap document nonterminal model-call resolution failures and shared output result retention. ❌ Live-model acceptance remains pending.

✅ [ADR 0111: Independent ASR/VAD selection](adr/0111-independent-asr-vad-selection.md) decouples the ASR switch from automatic Silero/Energy selection. Nemotron alone satisfies custom recognition prerequisites; Silero removal preserves ASR preference. ❌ Sustained device combination acceptance remains pending.

✅ ADR0103 failure isolation refinement: retained Action reports preserve later exceptions; invocation/resource rejection is call-local; Tools distinguish execution and feedback failures, with joined cooperative deadlines and task-scoped cancellation. ❌ Uncooperative handlers and physical acceptance remain outstanding.

✅ Directory contract audit reconciles Tools, Gateway dispatch/routing/results/validation, Agent generation/output/history and App lifecycle documentation with ADR0103. ❌ Live-provider/device acceptance remains separate from documentation and unit validation.

✅ Canonical ActionFunction owns static timeout and request-dependent execution budgets (including NexArm), shared by both call protocols. FunctionExecutor uses the declared budget before its30-second default; invalid explicit declarations fail without fallback. @Action creates protocol-neutral factories; host bindings select protocol/runtime policy. ❌ Deadlines cannot forcibly interrupt uncooperative cleanup.

✅ [ADR 0112: Gemma CoreAI chat](adr/0112-gemma-coreai-chat.md) replaces local Qwen/MLX with Gemma 4 E2B QAT CoreAI. iOS uses pinned h18p AOT resources; old Qwen downloads are incompatible. Shared package dependencies require OS 26; CoreAI execution requires OS 27. ✅ Mac real inference, cancellation and reload passed. ❌ Sustained device acceptance remains pending.

✅ [BLE pacing decision](adr/0123-nexarm-ble-shared-pacing.md) records transport admission, diagnostics and physical validation limits.

✅ [Bluetooth exception recovery](adr/0125-bluetooth-exception-recovery.md) records retry/cleanup/cancellation contracts and diagnostic cache bounds.

✅ [2026-10-04 installation evidence](Validation-History.md#2026-10-04--bluetooth-exception-recovery-installation): ADR0125 recovery and diagnostic UI compiled, passed signature/resource checks and installed on iPhone 17 Pro. ❌ Installation does not establish physical Bluetooth/robot or visual-layout acceptance.

✅ [2026-10-05 incident-sheet installation](Validation-History.md#2026-10-05--bluetooth-incident-sheet-iphone-installation): the latest working tree built with signing, passed signature/resource checks and installed on iPhone 17 Pro. ❌ Physical sheet interaction and BLE behavior remain unverified.

✅ [ADR0126](adr/0126-aim-worker-resource-ownership.md): fixes overlapping tracking Tool/worker fences and records resource conflicts separately from BLE recovery.

✅ [Tracking resource fix validation](Validation-History.md#2026-10-04--tracking-resource-ownership-fix): Gateway/worker/session regression tests and signed iPhone installation passed; physical tracking remains pending.

✅ [ADR0127](adr/0127-settings-manual-robot-takeover.md) documents Settings manual takeover and separate submission/completion boundaries with shared Action recipes. Native touch and physical acceptance remain pending.

✅ [ADR0128](adr/0128-settings-audio-detection.md) records Settings audio detection ownership, source-only perception, actual capture/fallback reporting and cleanup/freshness limits. ❌ Device capture and acoustic calibration remain pending.

✅ ADR0128: Settings preset/reset submission returns immediately; a cancellable background worker uses the shared Actions segment-feedback executor. Replacement joins software cleanup without waiting for arrival. ❌ Physical takeover/rhythm acceptance remains pending.

✅ [ADR0129](adr/0129-bluetooth-session-isolation.md) records independent Bluetooth recovery and Agent scheduling: native failures return through Action/Tool outcomes, accepted queues and Assistant/voice lifetime remain intact. Physical coexistence acceptance remains pending.

## Passive BLE connection — ADR0130

✅ Native connection/subscription completion makes Settings controls available immediately. App performs no connection pose/version/IK probe, stationary validation or indication movement. It listens to unsolicited position packets and publishes measured state; refresh reads the latest received packet only. Feedback silence remains visible but does not disable manual commands, disconnect or start recovery. Native write/connection failures remain explicit. Actions uses passive BLE compatibility for this App connection; recipe IK resolution is deferred to an explicit preset request, not connection verification. Manual jog can start from the existing configured reference when no sample has arrived; that reference is not measured telemetry. Segment arrival observation and cancellable replacement remain in Actions/App.

❌ Physical feedback cadence, preset IK availability and sustained manual takeover require real-device acceptance. Passive connection does not establish physical clearance or target arrival.

✅ Bluetooth connection-only presentation validation records UI-state and held-operation reconnect regressions separately from known failing legacy BLE/manual tests and physical iPhone acceptance.

✅ Bluetooth/execution audit evidence belongs to ADR0131 and Validation-History; the current Bluetooth presentation contract is ADR0134. Superseded connection/session policy in ADR0071 is explicitly historical. ❌ Physical BLE/UI acceptance remains pending.

✅ [ADR0133](adr/0133-motion-admission-and-terminal-reports.md) records the repeated-command bug fixes and independent native versus execution reporting. ❌ The reported phone behavior still needs verification on the revised build.

✅ ADR0134: Bluetooth exception history is removed at SDK/App/UI layers. Latest native connection, communication issue and recovery state alone appear in Settings; healthy snapshots/new connections replace prior faults. ADR0138 uses one row to connect while unconnected or open detail when already connected; connection success stays on the list, disconnect appears only when connected, and remembered devices remain forgettable; an already-open disconnected detail disables actions/motor gestures. Execution results/home issues and bounded automatic recovery remain independently owned. ❌ Physical BLE/navigation/touch acceptance remains pending.

✅ [ADR0134](adr/0134-bluetooth-current-state-and-navigation.md) is the current Bluetooth UI/state contract; earlier event-history decisions are explicitly superseded.

✅ [ADR0135](adr/0135-nexarm-aim-final-count.md) documents admitted final-count convergence and the distinct planner/physical boundaries. Supervised serial Settings/Agent trials and their explicit fixtures are recorded in [NexArm physical acceptance](NexArm_Physical_Acceptance.md). ❌ These trials are not BLE radio or native iPhone UI acceptance.

✅ [ADR0137](adr/0137-nexarm-ordinary-home.md) records the restored ordinary reset and its separation from tracking rest. Historical serial reset measurements are labeled by their pre-fix revision; restored phone posture is not yet physically accepted.

✅ [ADR0138](adr/0138-compact-bluetooth-device-list.md) replaces duplicate connection rows with state-based device-row taps, keeps detail navigation explicit and fixes successful-connection persistence of automatic reconnect. ❌ Native phone layout/gesture acceptance remains pending.


✅ [ADR0140](adr/0140-cancellation-safe-resource-cleanup.md) describes coordinator-owned bounded acknowledgment for cleanup entered from cancelled lifecycle tasks. ❌ Software cleanup does not establish physical robot stop.


✅ [ADR0141](adr/0141-resource-control-ownership.md) separates control ownership from device health/execution failure, with public unlocked/locked snapshots and automatic release after late cleanup. ❌ Physical stop and forced native-I/O isolation remain separate acceptance work.

✅ NexArm physical acceptance records the supervised 2026-10-05 aim-rate diagnostic, actual packet counts and user-observed motion/hold jitter distinction. ❌ Tracking tuning and physical root-cause attribution remain pending.

✅ [Agent-driven Storage stage validation](Validation-History.md#2026-10-06--agent-driven-app-storage-boundary-stage): targeted regressions and unsigned iOS device build passed. ❌ One full-run workflow timeout and simulator CoreAI availability remain explicit validation limits.

✅ [Shared history Tool validation](Validation-History.md#2026-10-06--shared-read-only-history-tools) records bounded-query regressions and unsigned iOS build success. ❌ Full-run audio diagnostic timeout, simulator dependency and live/UI acceptance remain separate limits.

✅ [History intent validation](Validation-History.md#2026-10-06--structured-history-refresh-intent): focused lifecycle/Gateway tests, six packaged Agent resources and unsigned iOS build passed. ❌ Existing full-run audio timeout and simulator dependency limits remain explicit.

✅ [Model resource interaction validation](Validation-History.md#2026-10-06--model-resource-interaction-ownership): full checks, final focused tests and unsigned device build passed. ❌ Simulator CoreAI dependency and native transfer acceptance remain pending.

✅ [History deletion validation](Validation-History.md#2026-10-06--history-deletion-and-deterministic-result-continuation): final full checks,15 focused tests and unsigned device build passed. ❌ Simulator CoreAI dependency and native confirmation acceptance remain pending.

✅ [Signal origin and returning Tool feedback](adr/0149-signal-origin-and-tool-feedback.md) records typed admission and stale-owner/causal fencing. ✅ ADR0163 adds Action/activity roots and typed history intent. ❌ Other typed host controls remain pending.

✅ Unified executable capabilities are implemented under the [active Agent-driven architecture](../MobileHarness/README.md#canonical-functions-and-protocol-bindings). The decisions below record the migration stages; their original transitional contracts are historical.

- [ADR0150](adr/0150-unified-execution-lifetime.md): shared deadlines, cancellation and joined cleanup.
- [ADR0151](adr/0151-consolidated-capability-sources.md): capability sources consolidated under Actions; temporary compatibility targets subsequently retired.
- [ADR0152](adr/0152-business-domain-capability-classification.md): six business-domain catalogs with cohesive UI/NexArm ownership.
- [ADR0153](adr/0153-three-level-capability-addressing.md) and [ADR0154](adr/0154-cohesive-capability-entry-files.md): directory/module-file/function ownership and addressing.
- [ADR0155](adr/0155-explicit-action-serialization-identity.md): serialization identity independent of address.
- [ADR0156](adr/0156-three-level-capability-addresses.md): explicit three-field addresses and Agent configuration v6.
- [ADR0157](adr/0157-canonical-executable-definitions.md): one definition/handler/outcome catalog, protocol projections, shared scheduled native execution, typed feedback and compatibility retirement.

❌ Remaining work is broader Agent-driven input/feature migration, bounded model continuation and physical acceptance; Action/Tool source and implementation consolidation is complete.

✅ [ADR0158 — Unified Action authoring](adr/0158-unified-action-authoring.md): one @Action attribute for all capabilities; model context supplies text actions and request tools supplies native declarations. Text tags and native events retain distinct ActionCall/ToolCall transports.

✅ [ADR0159 — Protocol-independent invocations](adr/0159-protocol-independent-action-invocations.md) removed native-only business signatures. ADR0161 completes the boundary with one FunctionInput/context/handler and @Action metadata; ActionInvocation remains a Gateway scheduling adapter. Differences remain in registration, model transport/parsing, runtime admission and feedback.

✅ [ADR0160 — Callable functions and protocol bindings](adr/0160-callable-functions-and-protocol-bindings.md) separates pure callable implementation from host registration/runtime protocol policy.

✅ [ADR0161 — Gateway execution and isolated function contracts](adr/0161-gateway-execution-and-function-contracts.md).

✅ [ADR0163 — Typed history and feedback causality](adr/0163-typed-history-and-feedback-causality.md): typed history.intent/1 and explicit Action/activity causal feedback. Remaining typed host controls, archive/title, resource/device Agent routes and bounded model continuation stay separate stages.

✅ ADR0166 records Agent-routed model resource commands; source/preferences/state migration remains outstanding.

✅ ADR0167 records actual speech binding through the resource Agent; source persistence/selection policy remains staged.

✅ ADR0168 records Agent-owned source/preferences transactions; the view draft is separate from the durable Action value.

✅ ADR0169 records Agent-routed resource inventory; registered UI effects and automatic observations remain outstanding.

- [ADR0170 — resource refresh presentation](adr/0170-agent-resource-refresh-presentation.md): ✅ Agent-selected, revision-fenced resource snapshot/query-failure presentation; other settings paths remain staged.

- [ADR0171 — root resource observations](adr/0171-root-resource-state-observations.md): ✅ Sequenced native invalidations and page-independent sampled presentation; native push/shared state remain outstanding.

- [ADR0172 — resource command failures](adr/0172-agent-resource-command-failures.md): ✅ Agent-selected operation-error presentation; preference/transport routes remain staged.

- [ADR0173 — resource preference failures](adr/0173-agent-resource-preference-failures.md): ✅ Agent-selected notices/error presentation, exact failure codes and per-request call bounds; host fallback remains staged.

- [ADR0174 — Resource host failure Signals](adr/0174-resource-host-failure-signals.md): ✅ Recoverable transport diagnostics through Agent-selected presentation; infrastructure fallback remains explicit.

- [ADR0175 — Agent-routed provider model discovery](adr/0175-agent-provider-model-discovery.md): ✅ Credential-free discovery intents and bounded canonical queries; transactions/presentation remain pending.

- [ADR0176 — Provider configuration transactions](adr/0176-agent-provider-configuration-transactions.md): ✅ Agent-selected restore/save, private credentials/results and Actions-owned apply/rollback. Registered provider UI effects/native acceptance remain pending.

Current existing-route migration: [provider presentation](adr/0177-agent-provider-presentation-and-policy.md), [bounded native continuation](adr/0178-bounded-native-result-continuation.md) and [device/navigation/environment](adr/0179-typed-device-navigation-environment.md). See [Roadmap](Roadmap.md#existing-route-completion-2026-10-08) for remaining extensions and [validation history](Validation-History.md) for acceptance limits.

Agent role organization: [ADR0180](adr/0180-memory-photographer-service-organization.md) records implemented Memory naming and Photographer business components; checks/device build passed, Simulator dependency blocked.

[Photographer camera control](adr/0181-photographer-camera-control.md) records the implemented migration of manual/model camera operations and its validation limits.


✅ [ApplicationControl service organization](adr/0182-application-control-service-organization.md): ADR0182 implements canonical role-directory, identity and host-transport migration; existing business behavior retained. Validation is recorded separately.

✅ [ADR0183](adr/0183-generation-round-observations.md): implemented Action/Tool split, registered observations and full-round result merge; physical/model acceptance remains pending.

✅ [ADR0184](adr/0184-assistant-photo-observation.md): Assistant photo Action, screenshot presentation and multimodal observation loop.

✅ [ADR0185](adr/0185-photo-save-and-ignore.md): Agent-driven current-photo save to system Photos and ignore from UI/dialogue; physical acceptance remains pending.

✅ [Independent Tool/Action consumer validation](Validation-History.md#2026-10-08--independent-tool-and-action-protocol-consumers) records focused regressions and unsigned iOS device build separately from full-run BLE fixture failures and the Simulator CoreAI dependency limit.

✅ [ADR0186](adr/0186-camera-lens-switch-lifetime.md): healthy lens input replacement completes independently of joined perception retirement; physical latency acceptance remains pending.

✅ [ADR0187 — Agent composition and ReACT](adr/0187-agent-composition-and-react.md): implemented abstraction and contracts; business roles retained, phase-two delegation remains separate.

✅ [Shared Agent source hierarchy - ADR0189](adr/0189-agent-support-hierarchy.md): implemented; repository checks and unsigned iOS device build passed.

✅ [SpeechPerception listening and one-way publication](adr/0190-assistant-listening-and-one-way-publication.md): resident perception authority, fixed listening Action, unacknowledged publication and recoverable speech errors. ❌ Physical acoustic acceptance pending.

✅ [SpeechPerception listening authority validation](Validation-History.md#2026-10-09--speechperception-listening-authority):651 integration and67 workflow tests plus unsigned iOS device build passed. ❌ Simulator CoreAI dependency, installation and physical acoustic acceptance remain outstanding.
