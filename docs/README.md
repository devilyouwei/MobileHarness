# Project documentation

Purpose: distinguish the current architecture and roadmap from historical design sources and experiment evidence.

✅ Architecture.md and Roadmap.md describe current implementation boundaries and outstanding acceptance work; ADRs record decisions, including Qwen3.5 MLX chat (0027).
✅ Retained experiment reports and original Technical_Design.docx provide historical evidence. The target technical plan is MobileHarness/README.md.
❌ Historical reports are not automatically current after model or prompt changes; consult dated raw evidence and module READMEs.

✅ The [Generation protocol reference](../MobileHarness/AgentCore/Generation/README.md) defines Function Token as mixed natural text and restricted XML, distinguishes parsed events from resolved calls, and documents the current FunctionTokenParser name.

✅ Current output terminology is Function Token for the mixed text/XML protocol, ActionCall for a resolved Action invocation, and ToolCall for a resolved native tool invocation.

✅ [Internal communication design](../MobileHarness/AgentCore/Communication/README.md) describes implemented direct event admission. Historical ADR 0028 proposed event/request transport; current lifecycle is governed by ADR 0048. ❌ Request/reply remains unimplemented.

✅ [Channel lock design](../MobileHarness/Gateway/Output/Scheduling/README.md#channel-lock-design) defines exclusive channel ownership and takeover boundaries. ❌ Enforcement and physical hold/stop remain unimplemented; current channels are unlocked.

✅ Architecture and Roadmap describe reply-error recovery and the MLX cache bound. ❌ iPhone retry stability remains an acceptance task.

✅ [Shared ModelManager](adr/0030-shared-model-manager.md) defines unified registration and lifecycle ownership. ❌ Device stability and automatic eviction remain pending.

✅ Model capability documentation covers the Qwen3.5 MLX production chat path and the shared management/resource contracts. Native CoreAI graph execution supports Nemotron ASR and diagnostic Kokoro TTS.

✅ ADR 0033 describes ModelKit as a project-internal foundation module; it is not independently packaged. Tests and application evaluations live under root Tests.

✅ [Internal default model assembly](adr/0034-modelkit-default-assembly.md) defines ModelKit-owned registrations and capability defaults. App supplies resources and handles OS events.

✅ ADR 0035 records YOLOv8 Pose capability and lifecycle integration. ❌ End-to-end camera/Agent acceptance remains outstanding.

✅ ADR 0036 documents camera change sampling, Photographer admission and Action-delivered skeletons.

✅ ADR 0035 and architecture/roadmap record the native pose preprocessing/postprocessing optimization and outstanding device re-acceptance.

✅ ADR 0037 records native pixel-buffer transport, opaque AgentCore attachments, Vision geometry and CPU+ANE defaults; the Photographer README contains the updated software/hardware Mermaid flow.

✅ ADR 0038 records the YOLO26-only model migration and verified end-to-end output contract.

✅ [Platform capability domains](adr/0039-platform-capability-domains.md) records Audio/Vision/Connectivity and shared Core directory ownership.

Current layer ownership is defined in the [ModelKit / PlatformKit comparison](../MobileHarness/README.md#391-platformkit-versus-modelkit): model-driven data processing versus device/OS data I/O. Dated ADRs and validation reports describe the implementation at that time; current module READMEs and Repository-Structure govern present ownership.


✅ ADR 0040 documents model-independent Gateway, JSON v4 static event communication and shared perception. ❌ Device acceptance and request/reply remain pending.

✅ ADR 0040 补充识别字幕 Action 决策：感知 Signal 与 UI.setTranscript 行为分离，App 不再通过转写观察修改字幕。

✅ [Skeleton visualization ownership](adr/0041-vision-perception-skeleton-action.md) moves UI.showPose into VisionPerception while retaining shared pose publications.

✅ ADR 0040 补充严格 UI Action 边界与 Assistant 清理归属，Signal 观察不得修改界面。

✅ [ShowPose completion Tool](adr/0042-show-pose-completion-tool.md) supersedes the Action execution path while preserving VisionPerception ownership.

✅ ADR 0043 records turn-scoped captions, atomic reply reset and actual-playback presentation.

✅ [Visual freshness](adr/0044-visual-freshness.md) records Agent-local latency isolation without Gateway protocol changes.

✅ [Audio spectrum telemetry](adr/0045-audio-spectrum-telemetry.md) records bounded FFT processing and render-cursor synchronization.

✅ [Semantic eye expressions](adr/0046-semantic-eye-expressions.md) records the no-emoji Action payload and native continuous animation design.

✅ [ADR 0047](adr/0047-explicit-input-routing.md) removes legacy input routers and default-Agent fallback; current Gateway entry points are publish and send.

✅ [ADR 0048](adr/0048-direct-signal-admission.md) makes Agent inboxes the sole pending-message queues. Gateways route and validate; InputGateway bounds structured direct calls; InternalSignalBus is removed. Action execution queues remain separate.
