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
