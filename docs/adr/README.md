# Architecture decisions

Purpose: preserve the reason, scope and consequences of implementation decisions.

✅ Numbered ADRs record staged architecture evolution; 0027 selects the Qwen3.5 MLX chat adapter without changing capability or Agent/Gateway contracts.
❌ Historical decisions may be superseded. Use Architecture.md, Roadmap.md and the latest relevant ADR for current behavior.

✅ Output contracts distinguish ActionCall from native ToolCall; Function Token names the mixed text/XML protocol interpreted inside Agents.

✅ [0028](0028-inter-agent-communication.md) specifies the internal Agent communication design. Runtime ports and configuration were subsequently implemented; ADR 0048 removes the separate Bus runtime.

✅ [0029](0029-channel-lock.md) defines channel lock ownership, immediate takeover and the separation between Agent decisions and runtime authorization. ❌ Runtime enforcement remains pending.

✅ [Shared ModelManager](0030-shared-model-manager.md) defines unified registration and lifecycle ownership. ❌ Device stability and timed idle eviction remain pending.

✅ Model capability documentation covers the Qwen3.5 MLX production chat path and the shared management/resource contracts. Native CoreAI graph execution supports Nemotron ASR and diagnostic Kokoro TTS.

✅ [ModelKit project boundary](0033-modelkit-project-boundary.md) defines the root-package build, Management/Backends ownership, root test separation and automated boundary checks.

✅ [Internal default model assembly](0034-modelkit-default-assembly.md) defines ModelKit-owned registrations and capability defaults. App supplies resources and handles OS events.

✅ 0035-yolov8-pose.md records bounded RGB pose inference and the separate Core ML adapter. ❌ Camera and device acceptance remain deferred.

✅ 0036-photographer-pipeline.md records the camera-to-Agent perception loop; physical robot behavior remains deferred.

✅ ADR 0035 amended for vImage preprocessing, reusable native buffers, stride-aware bulk pose tensor reads and unchanged runtime boundaries.

✅ [ADR 0037](0037-native-vision-pose.md): native camera/Vision pose path, CPU+ANE baseline and framework-independent Gateway transport.

✅ [ADR 0038](0038-yolo26-pose.md): pinned YOLO26n-Pose INT8 artifact replaces YOLOv8 with end-to-end decoding and no runtime fallback.

✅ [ADR 0039](0039-platform-capability-domains.md): PlatformKit capability domains, device I/O versus ModelKit data processing, and unchanged runtime ownership.

- [0040 — Shared perception and event routing](0040-shared-perception-and-event-routing.md): implemented Gateway boundary, JSON v4 and bounded event-only transport; device acceptance pending.

✅ ADR 0040 caption-action amendment routes recognition preview/clear through configured UI Actions; shared speech events remain unchanged.

✅ [ADR 0041](0041-vision-perception-skeleton-action.md): VisionPerception owns skeleton Actions; Photographer is reserved for future camera motion.

✅ ADR 0040 strict UI amendment separates observable speech facts from protocol-validated UI Actions.

✅ [ADR 0042](0042-show-pose-completion-tool.md): direct Void showPose Tool without Channel scheduling or result feedback.

- [0043 — Conversation turn presentation](0043-conversation-turn-presentation.md): runtime turn context, terminal recognition captions and atomic Assistant reset.

✅ [ADR 0044](0044-visual-freshness.md): bounded independent vision publication, latest skeleton state and maximum refresh admission.

✅ [ADR 0045](0045-audio-spectrum-telemetry.md): measured frequency bands and player render cursor replace synthetic audio animation.

✅ [ADR 0046](0046-semantic-eye-expressions.md): typed expressions, stable procedural eyes and uninterrupted native interpolation.

✅ [ADR 0047](0047-explicit-input-routing.md): explicit publish/send input routing, removal of legacy router and submit fallback, and static-policy regression tests.

✅ [ADR 0048](0048-direct-signal-admission.md): queue-free signal delivery, Agent-owned inbox policy and bounded structured Gateway admission without a Bus lifecycle.
