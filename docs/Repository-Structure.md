# 当前目录与维护约束

本轮起以 [新设计](../MobileHarness/README.md) 为目标分阶段迁移。App、Experience、Gateway、AgentCore、Agents、Actions、ActionRuntime、Tools 与 ToolRuntime 的现有实现已按新设计归位；逐项差异见 docs/Repository-Structure.md。详细状态见各目录 README，本次调整见 [ADR 0020](adr/0020-layout-alignment.md)。

现行设计以 MobileHarness/README.md 为准，旧 docs/Tech_Design.md 与原始 Word 仅作历史来源保留。未来模块按实际需求增加，不提前建立空实现。共享行为归 Actions，Agent 只保留配置声明与路径绑定。

## 目录与编译边界

| 物理目录 | 编译归属 | 当前职责 |
| --- | --- | --- |
| MobileHarness/App | Xcode App target | AppContainer 创建和注入依赖；AgentBootstrap 注册；AppLifecycleCoordinator 协调启动、语音任务与停止 |
| MobileHarness/Experience/Components | Xcode App target | 纯呈现圆环和字幕组件 |
| MobileHarness/Experience/Diagnostics | Xcode App target | 显式 Kokoro 验证入口 |
| MobileHarness/Experience/Conversation | Xcode App target | View 和 MainActor ViewModel；通过协调门面发出意图，不构造具体模型或 Agent |
| MobileHarness/Gateway/Input | Gateway | InputGateway 输入与 ASR；Routing/LogicRouter 确定性路由 |
| MobileHarness/Gateway/Output | Gateway | OutputGateway 协调；Validation 校验、Routing 分类、Dispatch 分发（Agent 内完成绑定） |
| MobileHarness/AgentCore | AgentCore | 根层 Agent、Descriptor、输入与身份契约 |
| MobileHarness/AgentCore/Runtime | AgentCore | Manager、Lifecycle 和 Status |
| MobileHarness/AgentCore/Capability | AgentCore | 局部能力与参数注册、路径绑定、提示构建 |
| MobileHarness/AgentCore/Generation | AgentCore | 共享 GhostShell 流式解析、文本映射、ToolCallParser |
| MobileHarness/AgentCore/Output | AgentCore | 已解析 ActionCall、ToolCall、ToolResult 与 envelope |
| MobileHarness/Gateway/Output/Scheduling | Gateway | Channel FIFO、模块资源互斥和完成/取消屏障 |
| MobileHarness/Agents/Assistant | Agents | 有界队列、会话历史、ChatCapability 与增量文本分句；从 Assistant.agent.json 加载能力，输出已解析 ActionCall/ToolCall |
| MobileHarness/ActionRuntime | ActionRuntime | ActionRegistry 路径白名单、ActionExecutor 执行与取消检查 |
| MobileHarness/Actions/Speech | Actions | speak 行为：通过抽象 TTS 合成并等待播放结束 |
| MobileHarness/Actions/UI | Actions | print 追加屏幕文字，express(emotion) 输出表情；显示服务由 App 注入 |
| MobileHarness/Tools/System | Tools | SystemTools.runtimeInfo 配置说明实现 |
| MobileHarness/ToolRuntime | ToolRuntime | ToolRegistry 注册与 ToolExecutor 执行分离 |
| MobileHarness/ModelKit（排除绑定、具体实现和后端） | ModelKit | 独立能力 SDK，Language/LLM、Language/JEV、Speech/ASR、Speech/TTS 及通用会话 |
| MobileHarness/ModelKit/Management | ModelKitRuntime | composition root 使用的 provider 注册、缓存和能力绑定 |
| MobileHarness/ModelKit/Speech/{ASR,TTS,Shared}/Apple | ModelKitAppleSpeech | 具体 Apple Speech SDK 适配、PCM 转换与分块 |
| MobileHarness/PlatformKit | PlatformKit | Audio 采集、播放和基础 VAD；Device 权限契约；ExternalDevice 传输契约 |
| MobileHarness/ModelKit/Speech/ASR/Nemotron | ModelKitNemotron | 流式预处理、RNN-T 解码、标准 ASR capability |
| MobileHarness/ModelKit/Speech/VAD/Silero | ModelKitSilero | 神经 VAD、流式上下文和 h/c 状态 |
| MobileHarness/ModelKit/Backends/CoreML | ModelKitCoreML | Core ML 图执行与 Float16 张量桥接 |
| MobileHarness/ModelKit/Backends/CoreAI | ModelKitCoreAI | CoreAI 图执行与张量桥接 |
| MobileHarness/Resources | 资源与本地制品 | 隐私清单；Models 清单；artifacts 权重不入 Git、真机仅打包 ios 制品 |
| Tests | Swift Testing targets | 能力契约、绑定、AppleSpeech 编解码/策略及跨模块 IntegrationTests |

根目录 Package.swift 直接映射这些路径，不复制源码、不再另建 Packages/HarnessKit 源码树。保留原有编译模块是因为它们已有独立测试价值，并可阻止 ModelKit 引用业务模块；这对应技术方案允许按测试和复用需求保留 Package 的例外。Xcode 的 HarnessKit product 仍作为 App 链接入口，名称不是物理目录。

ModelKit 的物理父目录不等于全部文件属于同一 Swift target：Runtime、Management 和具体模型子树明确排除在基础 SDK target 外。ModelKitRuntime 只依赖 ModelKit，ModelKitCoreAI 封装 Apple CoreAI；ModelKit 无 AgentCore、Gateway、PlatformKit 或业务依赖。这保留此前确认的独立 SDK 设计，不照搬技术方案 2.2 示意图中的 ModelKit → AgentCore 箭头。

## 新增和修改代码

1. 先按职责选择目录，再检查根 Package.swift 的 target 归属；禁止同一 Swift 文件同时由 App 和 Package 编译。
2. AppContainer 是具体适配器创建入口；页面通过 ConversationViewModel 和协调门面访问框架，不直接 import 具体模型。
3. Gateway 的实现按 Input/Output 归属；Agent 的业务实现按 Agents/具体名称归属；契约放 AgentCore，平台 SDK 对象留在 PlatformKit 或模型 adapter。
4. 可执行行为函数放 Actions 的功能模块。Agent 的独立 JSON 声明局部别名、路径、默认 Channel 与文本映射，加载生成 CapabilityRegistry，App 装配编译期 handler；Agent 不 import Actions，不直接调用模块函数。共享同一串行资源的行为放同一模块；有效 Channel 决定顺序，独立 Channel 且资源允许时并行。
5. 新增模型能力协议放 ModelKit 的能力子目录；具体 SDK 实现进入独立 adapter target，并在清单中排除出纯 ModelKit target。
6. 新增实际实现后同步 Xcode 导航引用；每个涉及的目录都维护 README，用 ✅/❌ 记录用途、设计目标和实现进度。尚未进入里程碑的目录不创建占位 Swift 文件。
7. 从根目录运行 scripts/check.sh 与 scripts/build-ios.sh。历史 Bootstrap-Validation.md 保留原验证时路径，不作为现行命令指南。

## 本次范围

初始目录迁移保留当时运行行为；当前双协议解析与 Channel 执行契约以 [ADR 0018](adr/0018-agent-protocols.md) 为准。AppRuntime 已拆为 AppContainer、AgentBootstrap、AppLifecycleCoordinator 和 ConversationViewModel。当前协调器仍承担前台语音会话编排；页面任务结束会停止当前运行。这些是现有阶段的限制，尚未实现技术方案中的完整长期运行服务与页面订阅分离。

Character、Camera、EventBus、完整 HybridRouter、完整跨模型调度及其他业务 Agent 均未实现，不通过创建目录宣称完成。macOS 目前只有共享模块测试能力，没有 App target。

模型层目录以 ADR 0006 为最新约定：Core 资源管理，Speech/ASR/Nemotron 模型算法和 capability，Backends/CoreAI 执行后端。Resources/Models/artifacts 为忽略 Git 的下载目录。已通过 AppContainer 的能力注入接入 App pipeline，参见 ADR 0007。

## 可选 iOS 27 LLM 包


## 与正式 README 第 37 节逐项核对（2026-09-24）

| 范围 | 核对结果 |
| --- | --- |
| App、Experience | ✅ 现有入口、Conversation、Components 归位；AppBootstrap 等装配辅助文件与 Diagnostics 为现有功能扩展。❌ Character、Camera 未实现 |
| Gateway/Input | ✅ InputGateway、Routing/SignalRouter 协议及 LogicRouter 归位。❌ Signal/SignalType/SignalAdapter/ContextBuilder、JEVRouter/AgenticRouter 尚未实现，不把 AgentInput 冒充完整 Signal |
| Gateway/Output | ✅ Validation、Routing、Dispatch、Scheduling/Channel 与 ChannelScheduler 归位。❌ 独立 GhostShellScheduler 未建，当前调度直接消费结构化调用 |
| AgentCore | ✅ 根契约、Runtime、Capability、Generation、Output 归位；ActionPath、AgentLifecycle 名称一致；ChannelParser 已拆分。❌ AgentContext、AgentRuntime、State、Bus、独立 CapabilityAlias 未实现 |
| Agents | ✅ Assistant 与独立 plist；❌ 其余五种业务 Agent 尚未实现 |
| Actions / ActionRuntime | ✅ Display → UI、Say → Speak、Actions/Runtime → ActionRuntime、ActionCatalog → ActionRegistry，并提取 ActionExecutor。❌ ActionResult、其余行为模块未实现 |
| Tools / ToolRuntime | ✅ System/RuntimeInfo 实现归位，ToolRegistry 与 ToolExecutor 分离。❌ 其他工具模块尚未实现 |
| ModelKit | ✅ 现有 Core、Speech、Language、Runtime 保留；VAD 和独立 adapter 为实际功能所需扩展。✅ Backends/MLX 与 Qwen35 adapter 已实现。❌ Vision、Embedding 未实现 |
| PlatformKit | ✅ 现有 Audio、Device、ExternalDevice；❌ Camera、Sensors、Storage、Network 具体实现未建立 |
| Resources | ✅ Models、隐私清单与现有资源；❌ 独立 Prompts/Assets 尚无需要迁入的实现 |
| Tests | 全部测试位于根 Tests；Qwen35Tests 不依赖业务，AgentModelEvaluationTests 负责业务评测；不复制到 MobileHarness/Tests |

AgentInput 和 ToolResult 是 AgentCore 的共享输入/输出契约。ToolResult 不移动到 ToolRuntime，避免 AgentCore → ToolRuntime → AgentCore 循环；不创建重复声明。设计大纲是目标职责布局，不是要求将真实扩展文件删掉或建立未实现占位目录。历史 ADR 记录当时状态，本表与各目录 README 记录现状。

## Cleanup after layout alignment

See ADR 0021: PlatformKit/Audio now contains MicrophoneFrame and StreamingMonoPCMResampler instead of VoiceSegmenter/MonoPCMResampler. Gateway/Input has no VoiceInputSession or batch recognition entry points. VAD emits audio/end events only; test fixtures do not remain in production Agents.

## Qwen3.5 MLX adapter

✅ `ModelKit/Backends/MLX` implements the local language backend and tokenizer bridge; `ModelKit/Language/LLM/Qwen35` implements ChatCapability. Both are separate targets declared in the root project package. `Tests/Qwen35Tests` contains contract, tokenizer-reference and opt-in real-model evaluation tests. The root SDK target excludes concrete Qwen sources.


## Planned Agent communication directory

`MobileHarness/AgentCore/Bus/README.md` contains the detailed communication design and is excluded from the AgentCore Swift target. This is a documentation-only directory: InternalSignalBus, messaging ports, tracking tables and request completion endpoints are not implemented. Gateway adapters belong in their existing Input/Output directories when implementation begins; AgentCore must not import Gateway. No placeholder Swift sources are added.

## Fixed local model resources

✅ App uses Nemotron ASR and Qwen3.5-2B chat. ModelManager owns instances and lifecycle; adapters load local model directories directly. Development JSON profiles pin downloads without runtime manifests or per-file SHA checks. Audio8/ONNX runtime targets and Audio8/4B weights are absent; their download profiles remain available for comparison. Simulator ASR and chat are unavailable.
❌ Device retry stability and sustained memory/thermal acceptance require physical testing. See ADR 0031.

✅ Root Package.swift owns all project targets. Qwen35Tests and AgentModelEvaluationTests are separate root test targets. ModelKit has no nested package or in-module tests.

✅ ModelKit/Core owns common media data, including AudioFrame/AudioFormat. ❌ Image/video contracts await concrete capability requirements; no placeholder implementation is present.
