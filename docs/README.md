# Project documentation

Purpose: distinguish the current architecture and roadmap from historical design sources and experiment evidence.

✅ Architecture.md and Roadmap.md describe current implementation boundaries and outstanding acceptance work; ADRs record decisions, including Qwen3.5 MLX chat (0027).
✅ Retained experiment reports and original Technical_Design.docx provide historical evidence. The target technical plan is MobileHarness/README.md.
❌ Historical reports are not automatically current after model or prompt changes; consult dated raw evidence and module READMEs.

✅ The [Generation protocol reference](../MobileHarness/AgentCore/Generation/README.md) defines Function Token as mixed natural text and restricted XML, distinguishes parsed events from resolved calls, and documents the current FunctionTokenParser name.

✅ Current output terminology is Function Token for the mixed text/XML protocol, ActionCall for a resolved Action invocation, and ToolCall for a resolved native tool invocation.

✅ [Internal communication design](../MobileHarness/AgentCore/Bus/README.md#inter-agent-communication-design) and [ADR 0028](adr/0028-inter-agent-communication.md) specify the planned event/request transport. ❌ The transport is not implemented.

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
