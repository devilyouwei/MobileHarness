# 架构与当前范围

本轮起以 [新设计](../MobileHarness/README.md) 为目标分阶段迁移。App、Experience、Gateway、AgentCore、Agents、Actions、ActionRuntime、Tools 与 ToolRuntime 的现有实现已按新设计归位；逐项差异见 docs/Repository-Structure.md。详细已实现/未实现状态见各目录 README，入口迁移见 [ADR 0017](adr/0017-entry-gateway-migration.md)。旧方案与历史 ADR 仅供追溯，当前目录核对以正式 README 为准。

旧版 [Tech_Design.md](Tech_Design.md) 与原始 `Technical_Design.docx` 保留不改。当前保留可用实现并按正式 README 分阶段迁移；共享行为函数根据用户后续要求统一放入 `Actions/`，增量约定见 [ADR 0015](adr/0015-function-actions.md) 和 [目录说明](Repository-Structure.md)。现有代码只实现方案的一部分，Roadmap 记录实际进度。

AppContainer 从 ModelKitDefaults 获取共享模型能力，并注入音频和显示服务；AgentBootstrap 注册 Agent、函数路径目录和 Tool；AppLifecycleCoordinator 协调前台语音与输出消费；Experience/Conversation 的 ViewModel 只转发状态和用户意图。尚未实现完整长期任务监督或页面订阅与运行生命周期分离。

## 依赖方向

```text
SwiftUI App → Agents / Gateway / Actions / ActionRuntime / Tools / ToolRuntime / PlatformKit / ModelKit / ModelKitDefaults / ModelKitRuntime
Gateway → AgentCore / ActionRuntime / ToolRuntime / ModelKit
Actions → AgentCore / ActionRuntime / ModelKit
ActionRuntime → AgentCore
Tools → AgentCore
Agents → AgentCore / ModelKit
ToolRuntime → AgentCore
ModelKitDefaults → ModelKitRuntime / ModelKit / 具体模型 adapter
ModelKitRuntime → ModelKit
ModelKitAppleSpeech → ModelKit / Speech / AVFAudio
ModelKitSilero → ModelKit / ModelKitCoreML → Apple CoreML
ModelKitNemotron → ModelKit / ModelKitCoreAI → Apple CoreAI
ModelKitQwen35 → ModelKit / ModelKitMLXLanguage → MLXLLM / MLX / Tokenizers
ModelKit → Foundation / Synchronization / CoreVideo 数据类型（无项目内依赖）
PlatformKit → Apple public frameworks
AgentCore → Foundation
```

ModelKit 是模型数据加工层：通过能力协议完成前处理、推理与后处理，provider 注册和默认绑定归内部 ModelKitDefaults。Agent 使用 ChatCapability、PoseCapability 等协议，Gateway 使用识别与 VAD 能力，Speech 动作使用 SpeechSynthesisCapability。具体模型、制品与后端对象不穿透这些接口。

PlatformKit 是设备/系统数据输入输出层：Audio 负责采集 PCM 与播放，Vision 负责采集图像与预览来源，Connectivity 定义外设通信契约，Core 保存通用权限契约。基础输入格式转换留在平台层；抽帧阈值、VAD 分段与路由属于 Gateway；模型输入缩放、推理和结果解码属于 ModelKit；业务决策属于 Agent。App 适配数据并注入服务，两套 Kit 互不依赖。Actions 通过注入的播放与显示服务完成副作用，Experience 负责 UI 呈现。详见 [职责对比](../MobileHarness/README.md#391-platformkit-versus-modelkit)。

## 已实现的数据流

真机仍使用 Nemotron + Silero 输入、Qwen3.5-2B MLX 聊天与 Apple 系统 TTS。模拟器仅供界面调试，无聊天能力回退。

```text
麦克风 → LiveSpeechInput / InputGateway → ASR partial 预览
VAD final → InputGateway → LogicRouter → AssistantAgent
ChatCapability 增量 → AgentGenerator / FunctionTokenParser
  → 文本分句 / 自闭动作 / Channel 栈
  → Agent 局部 CapabilityRegistry → ActionCall(path, channel, params)
  → OutputGateway → OutputValidator → ExecutionRouter → ActionDispatcher
  → ChannelScheduler → ActionRegistry handler → TTS / 实际播放 / 字幕
ToolCall(toolPath, arguments) → ToolDispatcher → ToolRegistry
  → ToolResult(callID) → InputGateway → 原 Agent/session
```

输入保留 inputID/sessionID，输出由 runtime 附加来源 Agent；模型不提供来源身份。AgentCore 不依赖 Actions、Gateway、ModelKit、SwiftUI 或具体设备。ModelKit 仍是独立 SDK。

## 两类 Agent 输出协议

共享解析器位于 AgentCore/Generation，每轮单独实例。动作必须自闭，Channel 必须成对；内层关闭恢复外层，最外层关闭后使用动作注册的默认 Channel。文本是内部 FunctionToken，Assistant 按短句映射 say 和 print；Channel 边界先冲刷旧文本，显式动作不隐式复制成文本动作。原始 XML 与未解析别名不离开 Agent。

每个 Agent 的 `<AgentName>.agent.plist` 是动作、工具、Channel 与文本映射的唯一声明来源。AgentConfigurations 从包资源加载，AgentConfiguration 校验 v1 标准后生成不可变快照；初始化失败回传 App，不使用硬编码回退。标准格式与开发流程见 [Agents 规范](../MobileHarness/Agents/README.md)，决策见 [ADR 0019](adr/0019-agent-configuration.md)。

CapabilityRegistry 在 Agent 内把局部别名解析成 ActionPath/toolPath，提供必填/可选字符串参数与 Channel 白名单。OutputValidator 复核已解析调用；Gateway 不再做别名绑定。App 仅注册明确路径的 handler，禁止反射执行模型路径。

ToolCallParser 是独立原生协议入口，完整 JSON 字符串参数映射为 ToolCall，保留 callID，不经 XML 或 Channel。当前 ChatCapability 尚无原生 tool delta，Assistant /status 继续使用注册的 System.runtimeInfo 工具。工具结果作为文字回复前转义，不能将结果中的标签变成动作。

AgentOutput 的模型执行载荷只有 actionCall/toolCall；暂保留 control 作为 runtime 完成/错误通知，后续再独立强类型运行事件。ActionCall 暂以 envelope 关联输入，未实现对外 invocation ID、标准 ActionResult 或持久幂等。

## Channel 与资源

调度器位于 Gateway/Output/Scheduling。每 Channel 默认 32 项（含执行中），最多 16 个活动 Channel、64 个来源 Agent/input 记录。队满明确失败，不能静默丢弃动作。相同 Channel 等待真实执行完成；不同 Channel 可并行，但同一动作 module 保持资源互斥，避免跨 Channel 同时使用扬声器。就绪队首按接纳顺序竞争资源；未实现优先级、抢占或通用资源依赖图。

Assistant 默认 Channel 为 Speech/Display，保留语音与字幕的既有并行；显式 main 可跨模块串行。Channel 关闭只影响后续 token 的归属，不撤销已接纳调用。所有 Agent 共享同名 Channel，完成/错误隔离键为 `(source, inputID)`。

## 生命周期、容量与取消

Assistant 为 actor，输入队列 32、输出流 128、单 worker。输入最多 4 KiB；模型输出最多 2000 UTF-8 字节、256 tokens、30 秒；每轮最多 120 个动作。成功后才保存同 session 的 4 轮历史，合计最多 1600 Character，按完整对话轮次裁剪。

解析器最多 65536 字节总输入、4096 字节标签、1024 标签、8 层 Channel。解释器有 2000 字节分句缓冲，失败实例不可复用；非法/截断 XML、错配关闭和超限明确失败。已流出动作不可回滚，运行错误取消未完成动作；取消不冲刷残余文本或标签。

assistant.finished 等待当前来源 Agent/input 的动作全部完成，语音端再延迟 350 ms 恢复监听。停止绕过满队列/暂停状态定向取消 Agent，取消动作并等待旧会话清理；权重驻留由共享 ModelManager 管理。相同物理资源直到 handler 清理完成才释放。

AgentManager 使用有界 AgentRegistry（64 个实例），生命周期仍为 registered/running/paused/stopped/failed。pause 阻止下一项但不打断已开始推理，stop 为终态。通用 AgentRuntime、StateStore、restart、健康监督、InternalSignalBus、长期后台运行仍未实现。

本轮决策与完整图见 [ADR 0018](adr/0018-agent-protocols.md)、[解析器](../MobileHarness/AgentCore/Generation/README.md)、[调度器](../MobileHarness/Gateway/Output/Scheduling/README.md)。

## 模型与扩展约束

基础 ModelKit 的部署基线保持 iOS 18/macOS 15；根 Package.swift 统一声明各 target，MLX 依赖只挂在对应后端 target。真机 App 链接 ModelKitQwen35，要求 iOS 27 与匹配 h18p 制品。资源白名单仅携带 Nemotron、Qwen35、Silero 与诊断用 Kokoro；模拟器不携带模型权重，ASR 和聊天能力明确不可用。权重、用户录音和本地签名设置不入 Git。

新增行为放 Actions 的实际功能模块，在 Agent CapabilityRegistry 声明能力与默认 Channel，在 App 注册路径 handler。权限与设备可用性在实际 adapter 验证，函数白名单不能替代系统权限或机器人急停。外部设备接入仍需参数 schema、期限、幂等、来源追踪和物理安全约束；iOS 后台执行不能承担安全保证。高频媒体队列可声明丢帧策略，控制命令、FunctionToken 和工具结果不可复用可丢帧通道。

相关决策：[独立能力 SDK](adr/0003-capability-sdk-boundary.md)、[语音圆环](adr/0012-live-voice-orb.md)、[分句函数与 Actions](adr/0015-function-actions.md)。

Kokoro 独立验证：新增 `ModelKitKokoro → ModelKit / ModelKitCoreAI`，通过原有 SpeechSynthesisCapability 输出 PCM。`KokoroValidation` scheme 打开英语试听页，不进入 Agent 对话；默认中文对话仍用系统 TTS。固定制品仅支持英语词典/af_heart，详见 [ADR 0016](adr/0016-kokoro-validation.md)。真机构建须先下载，包内额外包含 Kokoro；无自动下载或回退。

目录命名与运行时边界本轮对齐见 [ADR 0020](adr/0020-layout-alignment.md)。工具实现归 Tools，工具执行归 ToolRuntime；动作实现归 Actions，动作执行归 ActionRuntime。调度仍由 Gateway 管理。

Current voice input uses only streaming resampling, VoiceActivitySegmenter stream events and LiveSpeechInput. Obsolete batch recognition, duplicate utterance buffers and production demo construction have been removed; see ADR 0021.

Action cohesion: each concrete function owns its input validation, output checks, cleanup and any documented fallback. Small duplicated checks are preferred over coupling unrelated functions through a shared TextAction helper. Agent/Gateway structural and capability validation does not replace function-local checks. Existing invocation types and behavior are unchanged.

Current Agent capability configuration uses JSON v2 (<AgentName>.agent.json), with shared descriptive metadata retained in AgentCore. Parameter names derive from the parameter definitions; function-local conversion and semantic validation remain unchanged. Prompt insertion of the new metadata is deferred. See ADR 0022.

Capability visibility now follows JSON v3 hidden flags: hidden affects model context only, not registration or invocation permissions. Function-derived doc and XML Action examples replace the separate v2 descriptive fields. Native tools retain native JSON examples. See ADR 0023.

All facial expressions now use UI.express with the required emotion string. The independent UI.smile handler, Agent registration and /smile shortcut are removed; see ADR 0025. Historical quality reports preserve their original capability snapshots.

System-prompt capability guidance is Action-only: CapabilityContextBuilder emits visible Function Token registrations and never native Tool metadata, regardless of hidden. Tool registry/resolution/execution remain independent; native provider schema transport is still pending. See ADR 0026.

Current chat selection is Qwen3.5-2B 4-bit via MLX (ADR 0027). ModelKit contracts, Agent output protocols and Gateway behavior are unchanged.

Current parser terminology and the mixed natural-text/XML protocol are defined in [Generation](../MobileHarness/AgentCore/Generation/README.md). FunctionToken events are distinct from model tokenizer tokens and resolved ActionCall instances.

## Planned inter-Agent communication

The target contract is defined in [technical design section 32](../MobileHarness/README.md#32-internal-agent-communication) and [AgentCore/Bus](../MobileHarness/AgentCore/Bus/README.md#inter-agent-communication-design). AgentContext exposes bound messaging ports; every Agent send/reply crosses OutputGateway, and every delivery/completion crosses InputGateway. InternalSignalBus depends only on AgentCore protocols injected by App, preserving acyclic dependencies. InternalSignal is a runtime contract, separate from Function Token and native Tool Call model protocols.

Requests reserve result slots outside the business inbox; events support directed delivery and bounded static-topic fan-out. Limits, reply correlation, deduplication windows, deadlines, causal cycle rejection and cancellation are design requirements, not current implementation guarantees. No bus implementation or JSON communication fields are active. See [ADR 0028](adr/0028-inter-agent-communication.md).

## Channel ownership

ChannelScheduler.Channel carries declarative ChannelLockState with Agent/runtime-instance/session/lease identity and a monotonic deadline. Its current value is immutable unlocked: no lock acquisition, enforcement or release API is implemented. The target design in [section 20.1](../MobileHarness/README.md#201-channel-lock--exclusive-agent-control) and [Scheduling](../MobileHarness/Gateway/Output/Scheduling/README.md#channel-lock-design) provides atomic multi-channel leases through OutputGateway runtime control, independent of model output syntax.

Exclusive physical control additionally requires App-defined resource-domain coverage across all Action/Tool routes, cooperative cancellation, adapter stop acknowledgement and generation fencing. Acquiring a lock does not issue a hold Action. Expiry or owner loss requires safe cleanup without replaying stale motion. See [ADR 0029](adr/0029-channel-lock.md).

## Reply error recovery

An `assistant.error` terminates the current voice turn and cancels its Actions while retaining prepared model providers for an explicit user retry. Fresh parser/generation state is created for the next turn; failed output is not saved in history. Voice stop cancels sessions only; explicit manager unload/shutdown owns weight teardown. The MLX runtime caps reusable allocation cache at 64 MiB before loading; this is not a bound on total model or process memory.

## Shared model container

ModelKitRuntime.ModelManager unifies model registration, provider construction and model lifecycle. ModelKitDefaults registers context-bound factories; App retrieves capabilities with typed get. ModelKit.Core defines ModelContext and ModelResource; concrete adapters receive their managed handle rather than constructing private managers. Development download profiles select fixed revisions; backend SDKs load flat local model directories directly.

Get/load coalesce bounded construction/loading; unload gates a resource and waits for leases, shutdown cancels sessions and joins cleanup. Capability objects remain stable across unload/reload; every backend request acquires a managed lease. System speech also participates using lightweight resources with one operation slot. App obtains handles with deferred get, then prepares all conversation models before publishing its container. Startup shows a noninteractive loading ring; model failure remains explicit, including on the simulator. See [ADR 0030](adr/0030-shared-model-manager.md).

## Fixed local model resources

✅ App uses Nemotron ASR and Qwen3.5-2B chat. ModelManager owns instances and lifecycle; adapters load local model directories directly. Development JSON profiles pin downloads without runtime manifests or per-file SHA checks. Audio8/ONNX runtime targets and Audio8/4B weights are absent; their download profiles remain available for comparison. Simulator ASR and chat are unavailable.
❌ Device retry stability and sustained memory/thermal acceptance require physical testing. See ADR 0031.

## ModelKit resource policy

✅ ModelManager.get is the sole acquisition API. ModelContext management uses ModelManagement SPI. Residency includes unmanaged and is distinct from capability availability. ModelKitDefaults configures the MLX cache explicitly; App forwards coalesced memory warnings; releaseWhenIdle entries evict only loaded resources without active work. OperationAdmission rejects concurrent backend operations without a queue. See docs/adr/0032-modelkit-admission-and-memory-policy.md for the contract.
❌ Timed eviction, measured cross-model memory budgets and physical-device pressure/retry acceptance.

✅ The project declares Qwen3.5 and its MLX backend as separate targets in the root package. Native ModelKitCoreAI is shared by Nemotron and Kokoro and does not require CoreAILM.

## ModelKit project boundary

✅ Root Package.swift declares all targets. ModelKit stays inside this project with no nested package and no dependency on business targets. Management and Backends separate lifecycle control from engine execution. All tests live under root Tests; application prompt evaluations are isolated in AgentModelEvaluationTests. scripts/check.sh enforces import/target boundaries and directory READMEs. See ADR 0033 for the contract.
❌ Independent SDK distribution and physical-device acceptance are outside this migration.

✅ ModelKit/Core owns AudioFrame/AudioFormat and ImageFrame (RGB or retained read-only native buffer). PlatformKit owns capture data and device lifecycle; App adapts the data to model contracts. ❌ Model-level video sessions remain unimplemented.

✅ ModelKitDefaults owns fixed provider registration and default capability bindings. App supplies a resource root and retrieves interfaces with get(.chat) and the other capability keys. ModelKitRuntime remains adapter-independent. See [ADR 0034](adr/0034-modelkit-default-assembly.md).

✅ ModelKitDefaults.manager(resources:) returns the process-wide manager. Concurrent calls share assembly and provider instances; conflicting resource roots fail. Construction/registration are assembly SPI. Each model admits one active operation, rejects overlap with inputBusy, and releases admission only after cleanup. Cross-model scheduling is not implemented.

✅ PoseCapability adds single-image pose inference without business dependencies. ModelKitYOLOPose → ModelKit / ModelKitCoreML; Defaults owns the lazy `.pose` binding. See ADR 0035 and the adapter README. ✅ Camera → InputGateway → Photographer integration uses App-adapted frames and injected PoseCapability.

✅ Camera preview is a local presentation path: PlatformKit camera actor → native preview layer → Experience, coordinated by App independently of model readiness. The preview bypasses inference; a separate bounded native-frame path enters InputGateway and Photographer. Camera and voice retain separate permission/lifecycle control.

✅ Camera frames now enter InputGateway through CameraInputSession. Photographer owns latest-frame inference scheduling and result publication; ModelKit executes pose inference; UI.showPose executes via OutputGateway/ActionRuntime. No robot commands are implemented. ModelKit and AgentCore remain independent. See ADR 0036.

✅ Pose preprocessing uses Accelerate/vImage with actor-confined reusable buffers; typed bulk tensor extraction replaces NSNumber indexing. Immutable RGB capability and Gateway/Agent/Action contracts remain unchanged (ADR 0035 amendment).

✅ Native camera flow: retained read-only CVPixelBuffer → App opaque ImageAttachment → Gateway grayscale admission → Photographer resolver → ModelKit native ImageFrame → Vision scaleFit → Core ML CPU+ANE → CPU pose decoding → Action UI. AgentCore remains framework-independent; see ADR 0037.

✅ ADR 0038 replaces the pose artifact with pinned official YOLO26n-Pose INT8/end-to-end. The graph selects up to 300 rows; Swift performs score validation/filtering and coordinate restoration, with no second NMS. Vision+CPU/ANE remains the native path.

## 能力域目录（2026-09-26）

PlatformKit 以 Audio、Vision、Connectivity 组织设备/系统输入输出，Core 保存跨域权限契约；ModelKit 以 Speech、Language、Vision 组织模型数据处理。两层均按能力域分类，由 App 适配数据与注入服务，业务策略留在 Agent。相机源码移入 PlatformKit/Vision；共享音频会话仍由现有 AppleAudioIO 管理。此次仅调整目录和文档，不改变依赖、公开 API、队列或生命周期契约。见 [ADR 0039](adr/0039-platform-capability-domains.md)。
