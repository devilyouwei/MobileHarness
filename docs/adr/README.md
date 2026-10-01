# Architecture decisions

Purpose: preserve the reason, scope and consequences of implementation decisions. Design goal: make supersession visible without rewriting the original decision into a second current technical specification.

These are **dated decision records**, including proposals and stages later replaced. A status such as “accepted” or “implemented” describes that decision at its date, not today's behavior. Keep the original rationale and measurements for traceability; follow supersession notes and the [current module map](../../MobileHarness/README.md#project-structure) before treating any API, model, queue or file path as current.

✅ Numbered ADRs record staged architecture evolution; 0027 selects the Qwen3.5 MLX chat adapter without changing capability or Agent/Gateway contracts.
❌ Historical decisions may be superseded. Use the [public architecture](../Architecture.md) and [roadmap](../Roadmap.md) for current scope, and follow the [module design index](../../MobileHarness/README.md#part-ii--module-design) to the relevant README for exact implementation contracts.

✅ Output contracts distinguish ActionCall from native ToolCall; Function Token names the mixed text/XML protocol interpreted inside Agents.

✅ [0028](0028-inter-agent-communication.md) records the original Bus-based Agent communication design; [0048](0048-direct-signal-admission.md) removes that transport runtime.

✅ [0029](0029-channel-lock.md) defines channel lock ownership, immediate takeover and the separation between Agent decisions and runtime authorization. ❌ Runtime enforcement remains pending.

✅ [Shared ModelManager](0030-shared-model-manager.md) defines unified registration and lifecycle ownership. ❌ Device stability and timed idle eviction remain pending.

✅ Model capability decisions cover the Qwen3.5 MLX chat path and shared management/resource contracts. Later ADRs replace diagnostic Kokoro with the default bilingual Core ML path; the individual decisions retain their dated context.

✅ [ModelKit project boundary](0033-modelkit-project-boundary.md) defines the root-package build, Management/Backends ownership, root test separation and automated boundary checks.

✅ [Internal default model assembly](0034-modelkit-default-assembly.md) defines ModelKit-owned registrations and capability defaults. App supplies resources and handles OS events.

✅ [0035](0035-yolov8-pose.md) records the former YOLOv8 model choice and bounded RGB inference; [0038](0038-yolo26-pose.md) replaces the model. ❌ Device acceptance remains deferred.

✅ [ADR 0036](0036-photographer-pipeline.md) records the former camera-to-Photographer perception loop, later superseded for skeleton display by [ADR 0041](0041-vision-perception-skeleton-action.md); physical robot behavior remains a [proposal](../Photographer-Proposal.md).

✅ ADR 0035 amended for vImage preprocessing, reusable native buffers, stride-aware bulk pose tensor reads and unchanged runtime boundaries.

✅ [ADR 0037](0037-native-vision-pose.md): native camera/Vision pose path, CPU+ANE baseline and framework-independent Gateway transport.

✅ [ADR 0038](0038-yolo26-pose.md): pinned YOLO26n-Pose INT8 artifact replaces YOLOv8 with end-to-end decoding and no runtime fallback.

✅ [ADR 0039](0039-platform-capability-domains.md): PlatformKit capability domains, device I/O versus ModelKit data processing, and unchanged runtime ownership.

- [0040 — Shared perception and event routing](0040-shared-perception-and-event-routing.md): introduced the Gateway/perception boundary and JSON v4; [0048](0048-direct-signal-admission.md) later removed its Bus/transport queues. Device acceptance is pending.

✅ ADR 0040 caption-action amendment routes recognition preview/clear through configured UI Actions; shared speech events remain unchanged.

✅ [ADR 0041](0041-vision-perception-skeleton-action.md): moved skeleton display from Photographer to VisionPerception; [0042](0042-show-pose-completion-tool.md) later changed display from Action to Tool.

✅ ADR 0040 strict UI amendment separates observable speech facts from protocol-validated UI Actions.

✅ [ADR 0042](0042-show-pose-completion-tool.md): direct Void showPose Tool without Channel scheduling or result feedback.

- [0043 — Conversation turn presentation](0043-conversation-turn-presentation.md): runtime turn context, terminal recognition captions and atomic Assistant reset.

✅ [ADR 0044](0044-visual-freshness.md): bounded independent vision publication, latest skeleton state and maximum refresh admission.

✅ [ADR 0045](0045-audio-spectrum-telemetry.md): measured frequency bands and player render cursor replace synthetic audio animation.

✅ [ADR 0046](0046-semantic-eye-expressions.md): typed expressions, stable procedural eyes and uninterrupted native interpolation.

✅ [ADR 0047](0047-explicit-input-routing.md): explicit publish/send input routing, removal of legacy router and submit fallback, and static-policy regression tests.

✅ [ADR 0048](0048-direct-signal-admission.md): queue-free signal delivery, Agent-owned inbox policy and bounded structured Gateway admission without a Bus lifecycle.

✅ [ADR 0049](0049-perception-eye-gaze.md): YOLO facial landmarks to UI.moveEyes, bounded state replacement and mandatory Action completion barrier.

✅ [0050 — Default Kokoro synthesis](0050-default-kokoro-synthesis.md): historical English-only default; [0052](0052-kokoro-coreml-bilingual.md) replaces it with bilingual Core ML speech.

- ✅ [0051: OpenAI-compatible cloud chat](0051-openai-compatible-chat.md) establishes the adapter; [0053](0053-settings-live-chat.md) adds credential UI and live selection. ❌ Real-provider acceptance remains pending.

✅ [0052 — Kokoro Core ML bilingual synthesis](0052-kokoro-coreml-bilingual.md): local Mandarin/English resources, script-aware speech and process-owned model lifetime.

- ✅ [0053: Settings and live cloud selection](0053-settings-live-chat.md); ❌ real provider acceptance pending.



- ✅ [0055 — Synthesis Agent and audio handles](0055-synthesis-agent-audio-handles.md): independent FIFO synthesis, shared bounded PCM and state-based expiration. ❌ Device acceptance pending.

- ✅ [0056 — Shared Storage core and PCM adapter](0056-storage-audio-migration.md): Foundation-only bounded memory and leases with a separate PCM adapter; disk persistence remains future work.

✅ [ADR 0057](0057-local-settings-storage.md) records local document cache/persistence synchronization and user-settings migration. ❌ Cross-device synchronization remains deferred.


✅ [0058 — MOSS-TTS-Nano default synthesis](0058-moss-tts-nano.md): replaces the production Kokoro path with bounded local MOSS streaming. ❌ Physical-device acceptance remains pending.

✅ ADR 0053 now records optional cloud authentication, official endpoint fallback and the visible default chat model. ❌ Model discovery cannot guarantee third-party chat compatibility.


✅ [0059 — Structured wait scheduling](0059-structured-wait-scheduling.md): task-local groups, typed boundaries, module exclusion and cancellation. Supersedes module FIFO in ADR 0015 and the shared-lane scheduling portion of ADR 0018. ❌ Cross-task barriers, preemption and rollback remain deferred.

✅ [0060 — Persistent conversation history](0060-persistent-conversation-history.md): actual user/raw model/request records, explicit logical conversation reset and title-only archival summaries. ❌ Live-model title quality and device performance remain unverified.

✅ [0061 — Agent JSON v5](0061-agent-json-v5.md): Channel-grouped model Actions and code-owned internal permissions replace redundant hidden/text declarations. ❌ Full JSON Schema/native Tool streaming are not included.

✅ [0062 — Optional output-token budgets](0062-default-chat-output-budget.md): provider defaults for Assistant, bounded local context and backward-compatible history records. ❌ Live-provider acceptance remains separate.

✅ [0063 — Module directory consolidation](0063-module-directory-consolidation.md): Actions/Tools each own Runtime; Agents owns Core with independent AgentCore compilation. Its former App/Views ownership is superseded by ADR 0064's sibling UI module. ❌ No behavior change or new device acceptance is implied.

- [ADR 0064 — App and UI boundaries](0064-app-ui-boundaries.md): explicit composition, independently compiled pages and application workflows.

✅ [ADR 0065 — Action runtime contracts](0065-action-runtime-contracts.md): validated implementation metadata, startup coverage, consistent invocation, typed arguments, error separation and bounded diagnostics. ❌ Activity/resource ownership and full business Action style migration remain deferred.

## 0066 — Action results and resources

✅ [0066-action-results-resource-leases.md](0066-action-results-resource-leases.md) records bounded terminal feedback, typed activity completion, group leases/fences and the camera lifecycle integration. ❌ Durable feedback and all-device migration remain outstanding.

## 0067 — Domain-owned behavior assembly

✅ [0067-domain-owned-behavior-assembly.md](0067-domain-owned-behavior-assembly.md) records domain catalogs, typed capabilities and complete startup registry validation. ❌ Native capability additions still require host bindings.

## Canonical Action entry audit

✅ [0068-canonical-action-entrypoints.md](0068-canonical-action-entrypoints.md) records canonical UI/Speech namespaces, entry signatures and typed audio handles. ❌ Device/animation follow-ups remain separate.

## Storage core/domain layout

✅ [0069-storage-core-domain-layout.md](0069-storage-core-domain-layout.md) separates Storage core mechanisms from Audio/Chat domain targets.

❌ Image/video/semantic-memory storage and cross-device synchronization remain planned.

✅ [0070 — NexArm USB diagnostic](0070-nexarm-usb-diagnostic.md): first bounded real-device Action, separate from production autonomous control. ❌ BLE/TCP and physical watchdog acceptance remain pending.

✅ ADR 0070 extended with bounded Assistant base sweeps and typed host binding; ❌ hardware stop/watchdog remains unverified.

✅ [0071 — iPhone NexArm BLE](0071-nexarm-iphone-ble.md): settings and root-owned BLE-to-Action chain. ❌ Unattended operation and physical stop/watchdog remain deferred.

✅ ADR 0071 now records retained BLE connections with control admission closed when AT32 version is unavailable, and explicit read-only revalidation. ❌ Device-side readout stability remains unverified.

✅ ADR 0071 includes one reset and bounded ID5 movement as explicit connection feedback, with joined cancellation and readiness only after position verification. ❌ Physical acceptance pending.

✅ ADR 0071 revises the earlier strict BLE gate using physical USB/BLE evidence: named compatibility profile, stationary telemetry checks, missing-version disclosure, and one reset/ID5 ±8° indication. ❌ No claim of iPhone physical acceptance.

✅ ADR 0071 includes the current BLE UX contract: no normal firmware query, name-independent discovery, one read-only recovery attempt on activation, persisted opt-out after manual disconnect/forget, and no motion replay.

## NexArm entertainment skills (2026-09-30)

- ✅ [0072 — NexArm entertainment skills](0072-nexarm-entertainment-skills.md): bounded presets, typed bindings, terminal feedback and no replay. ❌ Physical sequence acceptance pending.

- ✅ [0073 — Peripheral detail controls](0073-peripheral-detail-controls.md): root-owned manual actions, sampled telemetry and bounded six-motor adjustments. ❌ Physical acceptance pending.

✅ ADR 0073 amendment: preserve live Bluetooth connection after uncertain motion, with bounded read-only recovery and no replay. ❌ Physical acceptance pending.

✅ ADR 0073 lifecycle amendment separates connection indication from protocol readiness, adds bounded native-link recovery and defines complete App-owned discovery/forget cleanup. ❌ Physical acceptance pending.

- ✅ [0074 — NexArm live jog](0074-nexarm-live-jog.md): spring-return speed controls, bounded native no-response admission and priority reset. ❌ Physical acceptance pending.

- ✅ [0075 — Fixed NexArm choreography](0075-nexarm-fixed-choreography.md): complete absolute presets and synchronized servo transitions; ❌ physical acceptance pending.

- ✅ [0076 — NexArm controller preset transport](0076-nexarm-controller-preset-transport.md): use established CMD51 and preserve failure details; ❌ physical confirmation pending.

- ✅ [0077 — Calibrated NexArm pose choreography](0077-nexarm-calibrated-pose-choreography.md): fixed physical poses, device IK and large/fast phone base sway; ❌ physical acceptance pending.

- ✅ [0078 — Shared NexArm physical validation](0078-nexarm-shared-physical-validation.md): identical controller over USB/BLE, absolute pose commands and physical evidence; ❌ BLE timing/visual acceptance separate.

✅ 2026-09-30: shared NexArm jog planner uses bounded acceleration/jerk, finite look-ahead, 30 ms scheduling and native servo position writes without per-write pose queries. Tests cover smoothing, duplicate suppression, six-axis streaming, congestion and reset preemption. See [ADR 0079](0079-nexarm-smooth-jog.md). ❌ BLE physical cadence/visual smoothness require phone acceptance.

✅ [0080 — Independent NexArm motion results](0080-nexarm-independent-motion-results.md) removes prior-result locks from new explicit preset requests; ❌ physical failure recovery acceptance remains pending.

✅ [0081 — Settings immediate test control](0081-settings-immediate-test-control.md) records latest-request replacement without feedback waits; ❌ delivery is not completion.

✅ [0082 — NexArm observation watchdogs](0082-nexarm-observation-watchdogs.md) bounds channel await without query-response blocking; ❌ no device-side stop guarantee.

✅ ADR0082 clarifies whole-action budget composition after isolated USB dance reproduction: sum per-segment allowances without extending the fixed deadline during playback.

- [0083 — Unified Action execution presentation](0083-action-execution-presentation.md): bounded scheduler snapshots, root-owned UI projection and honest cancellation/completion states.

- ✅ [0084 — LLM output buffering](0084-llm-output-buffering.md): unbounded pending-event count for finite chat generation; other queue policies remain. ❌ Device acceptance pending.

- ✅ [0085 — Reply-owned speech audio](0085-reply-owned-speech-audio.md): no queued/ready PCM expiry; completion/interruption cleanup follows the reply owner. ❌ Physical-device acceptance remains pending.

✅ ADR 0070 now records retirement of the unused wrist diagnostic Action; direct controller diagnostics remain outside the Agent capability catalog.

- [0086 — Domain-owned Action display metadata](0086-action-display-metadata.md): self-described execution records, subscription-only Workflow and generic UI presentation.

✅ ADR 0082 extends the earlier head handoff protection to all conversation trajectory segments; ❌ physical celebration/dance jitter acceptance remains pending.

- ✅ [0087 — Producer-owned speech deadline](0087-speech-producer-deadline.md): PCM reads follow producer completion/failure/cancellation without a default three-second cutoff; synthesis and hardware deadlines remain. ❌ Audible device acceptance remains pending.

- ✅ [0088 — Settings-matched NexArm Cartesian playback](0088-nexarm-settings-matched-playback.md): shared finite plan/cadence, final-home observation and retained whole-Action exclusion; ❌ physical phone acceptance pending.

- ✅ [0089: NexArm arm completion scope](0089-nexarm-arm-completion-scope.md) excludes unrelated gripper state from performance completion while retaining strict generic tracking.

- ✅ [0090 — NexArm arm-only motion packets](0090-nexarm-arm-only-motion-packets.md): read-only device IK, explicit motors1–5, gripper-independent reset and Settings estimates. ❌ Loaded-arm/BLE endurance acceptance.

## Photographer aim

✅ [0091 — Photographer aim](0091-photographer-aim.md) subscribes Photographer to `vision.pose` and sends logical aim as an internal Tool plus a motors-1–5 packet. The suction-cup gripper is not addressed. ❌ The camera session leaves arm control off and does not call the production NexArm controller.
