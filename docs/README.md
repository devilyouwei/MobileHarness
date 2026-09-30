# Project documentation

Purpose: collect project requirements, public technical explanations, change history, test evidence, delivery plans, future proposals, original design sources and required license notices without duplicating current module implementation contracts. Design goals: help readers distinguish what works now, what was decided earlier and what still needs acceptance.

## Documentation ownership

| Location | Owns | Does not own |
| --- | --- | --- |
| [MobileHarness/README.md](../MobileHarness/README.md) | Target technical plan, module map and cross-module design rules | Detailed queue algorithms or per-module API contracts |
| `MobileHarness/<module>/README.md` | Current module purpose, design goals, implemented/outstanding behavior, exact limits, failure and lifecycle contracts | Project requirements, change logs or speculative designs |
| `docs/` requirements and public explanations | Product goals, user scenarios, externally understandable capabilities and system-level explanation | Code-level implementation contracts |
| [Architecture.md](Architecture.md) | Current dependency direction and end-to-end ownership across modules, written for readers outside a single module | Copies of module parameters or dated implementation journals |
| [Roadmap.md](Roadmap.md) and future proposals | Milestone status, planned features, unimplemented technical options and acceptance state | A second implementation specification or an implied claim of implementation |
| [ADR index](adr/README.md) and change records | Why and when a decision or contract changed; supersession links | The sole source for today's exact API/limit values |
| Validation reports, including [Voice.md](Voice.md) | Reproducible checks, raw measurements, observations and device acceptance criteria | Module design or implementation details |

When a runtime contract changes, update the owning module README first, then the affected project-level boundary, decision/change record and roadmap. Link to the module README instead of copying its limits into another current document. Mark future ideas as **proposed**, delivered behavior as **implemented**, and measurements with date, environment and method. A proposal in `docs/` does not authorize a code directory or become a current contract. Keep dated ADRs and validation reports as historical evidence, clearly linking a superseding decision when needed.

✅ Current entry points: [technical plan and source map](../MobileHarness/README.md), [public architecture](Architecture.md), [roadmap](Roadmap.md), [Photographer proposal](Photographer-Proposal.md), [decisions](adr/README.md), [change history](Change-Log.md), [test records](Validation-History.md) and [voice acceptance](Voice.md). [Storage](../MobileHarness/Storage/README.md) and [StorageAudio](../MobileHarness/Storage/Audio/README.md) own the current memory/PCM contracts. Existing dated validation reports remain under `docs/`.

❌ A unified project requirements document and a dedicated proposal index have not yet been created; the current [Photographer proposal](Photographer-Proposal.md) is linked directly until there are enough proposals to index. Historical reports are not automatically current after model or prompt changes. The original `Technical_Design.docx` and historical `Tech_Design.md` remain source material, not current module specifications.

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
