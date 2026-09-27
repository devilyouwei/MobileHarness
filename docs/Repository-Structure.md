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
| MobileHarness/Gateway/Input | Gateway | InputGateway 协议校验、静态订阅与定向投递；无 ModelKit 依赖 |
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
| MobileHarness/ModelKit（排除绑定、具体实现和后端） | ModelKit | 模型数据处理 SDK：Language、Speech、Vision 能力协议及通用数据/会话契约 |
| MobileHarness/ModelKit/Management | ModelKitRuntime | 内部 Defaults 使用的 provider 注册与绑定；共享缓存、获取与模型生命周期 |
| MobileHarness/ModelKit/Speech/{ASR,TTS,Shared}/Apple | ModelKitAppleSpeech | 具体 Apple Speech SDK 适配、PCM 转换与分块 |
| MobileHarness/PlatformKit | PlatformKit | Audio 采集/播放；Vision 相机输入/预览；Core 权限契约；Connectivity 外设传输契约 |
| MobileHarness/ModelKit/Speech/ASR/Nemotron | ModelKitNemotron | 流式预处理、RNN-T 解码、标准 ASR capability |
| MobileHarness/ModelKit/Speech/VAD/Silero | ModelKitSilero | 神经 VAD、流式上下文和 h/c 状态 |
| MobileHarness/ModelKit/Backends/CoreML | ModelKitCoreML | Core ML 图执行与 Float16 张量桥接 |
| MobileHarness/ModelKit/Backends/CoreAI | ModelKitCoreAI | CoreAI 图执行与张量桥接 |
| MobileHarness/Resources | 资源与本地制品 | 隐私清单；Models 清单；artifacts 权重不入 Git、真机仅打包 ios 制品 |
| Tests | Swift Testing targets | 能力契约、绑定、AppleSpeech 编解码/策略及跨模块 IntegrationTests |

根目录 Package.swift 直接映射这些路径，不复制源码、不再另建 Packages/HarnessKit 源码树。保留原有编译模块是因为它们已有独立测试价值，并可阻止 ModelKit 引用业务模块；这对应技术方案允许按测试和复用需求保留 Package 的例外。Xcode 的 HarnessKit product 仍作为 App 链接入口，名称不是物理目录。

ModelKit 的物理父目录不等于全部文件属于同一 Swift target：Defaults、Management、Backends 和具体模型子树明确排除在基础 SDK target 外。ModelKitRuntime 只依赖 ModelKit，ModelKitCoreAI 封装 Apple CoreAI；ModelKit 无 AgentCore、Gateway、PlatformKit 或业务依赖。两套 Kit 按能力域组织，分别负责模型加工与设备输入输出；App 适配数据和注入服务，Gateway 承担协议接纳和投递；感知 Agent 承担采样/模型加工策略，业务 Agent 承担任务决策。

## 新增和修改代码

1. 先按职责选择目录，再检查根 Package.swift 的 target 归属；禁止同一 Swift 文件同时由 App 和 Package 编译。
2. AppContainer 从 ModelKitDefaults 获取模型能力并创建平台服务；页面通过 ConversationViewModel 和协调门面访问框架，不直接 import 具体模型。
3. Gateway 的实现按 Input/Output 归属；Agent 的业务实现按 Agents/具体名称归属；契约放 AgentCore，设备资源留在 PlatformKit，模型执行对象留在 adapter/backend；ModelKit/Core 可提供受约束的只读 CoreVideo 图像数据封装，不拥有相机设备。
4. 可执行行为函数放 Actions 的功能模块。Agent 的独立 JSON 声明局部别名、路径、默认 Channel 与文本映射，加载生成 CapabilityRegistry，App 装配编译期 handler；Agent 不 import Actions，不直接调用模块函数。共享同一串行资源的行为放同一模块；有效 Channel 决定顺序，独立 Channel 且资源允许时并行。
5. 新增模型能力协议放 ModelKit 的能力子目录；具体 SDK 实现进入独立 adapter target，并在清单中排除出纯 ModelKit target。
6. 新增实际实现后同步 Xcode 导航引用；每个涉及的目录都维护 README，用 ✅/❌ 记录用途、设计目标和实现进度。尚未进入里程碑的目录不创建占位 Swift 文件。
7. 从根目录运行 scripts/check.sh 与 scripts/build-ios.sh。历史 Bootstrap-Validation.md 保留原验证时路径，不作为现行命令指南。

## 本次范围

初始目录迁移保留当时运行行为；当前双协议解析与 Channel 执行契约以 [ADR 0018](adr/0018-agent-protocols.md) 为准。AppRuntime 已拆为 AppContainer、AgentBootstrap、AppLifecycleCoordinator 和 ConversationViewModel。当前协调器仍承担前台语音会话编排；页面任务结束会停止当前运行。这些是现有阶段的限制，尚未实现技术方案中的完整长期运行服务与页面订阅分离。

Camera 与共享视觉感知已实现；Character、完整请求/回复、模型路由判断、完整跨模型调度及其他业务 Agent 尚未实现，不通过创建目录宣称完成。macOS 目前只有共享模块测试能力，没有 App target。

模型层目录以 ADR 0006 为最新约定：Core 资源管理，Speech/ASR/Nemotron 模型算法和 capability，Backends/CoreAI 执行后端。Resources/Models/artifacts 为忽略 Git 的下载目录。已通过 AppContainer 的能力注入接入 App pipeline，参见 ADR 0007。

## 可选 iOS 27 LLM 包


## 与正式 README 第 37 节逐项核对（2026-09-24）

| 范围 | 核对结果 |
| --- | --- |
| App、Experience | ✅ 现有入口、Conversation、Components 归位；AppBootstrap 等装配辅助文件与 Diagnostics 为现有功能扩展。✅ Camera 预览、控件与骨架覆盖；❌ Character 未实现 |
| Gateway/Input | ✅ InputGateway 提供 publish 静态订阅与 send 显式定向投递；旧 Input/Routing 目录及 submit 回退入口已移除。✅ 统一使用 AgentCore.AgentInput；模型路由判断移至未来独立 Agent，不新增重复 Signal 或 Gateway 模型路由器 |
| Gateway/Output | ✅ Validation、Routing、Dispatch、Scheduling/Channel 与 ChannelScheduler 归位。❌ 独立 GhostShellScheduler 未建，当前调度直接消费结构化调用 |
| AgentCore | ✅ 根契约、Runtime、Capability、Generation、Output 归位；ActionPath、AgentLifecycle 名称一致；ChannelParser 已拆分。✅ Bus 事件通信已实现；❌ 通用 AgentContext、AgentRuntime、State、请求/回复与独立 CapabilityAlias 未实现 |
| Agents | ✅ Assistant、SpeechPerception、VisionPerception 与独立 JSON v4；Photographer 仅保留运镜设计文档；❌ 其他业务 Agent 尚未实现 |
| Actions / ActionRuntime | ✅ Display → UI、Say → Speak、Actions/Runtime → ActionRuntime、ActionCatalog → ActionRegistry，并提取 ActionExecutor。❌ ActionResult、其余行为模块未实现 |
| Tools / ToolRuntime | ✅ System/RuntimeInfo 实现归位，ToolRegistry 与 ToolExecutor 分离。❌ 其他工具模块尚未实现 |
| ModelKit | ✅ Core、Speech、Language、Vision、Defaults、Management 与 Backends；YOLO、Qwen35 等为独立 adapter target。❌ 其他视觉模型与 Embedding 未实现 |
| PlatformKit | ✅ Audio、Vision 能力域；Core 通用权限契约；Connectivity 外设通信契约。❌ 具体外设传输及其他能力域按需求实现 |
| Resources | ✅ Models、隐私清单与现有资源；❌ 独立 Prompts/Assets 尚无需要迁入的实现 |
| Tests | 全部测试位于根 Tests；Qwen35Tests 不依赖业务，AgentModelEvaluationTests 负责业务评测；不复制到 MobileHarness/Tests |

AgentInput 和 ToolResult 是 AgentCore 的共享输入/输出契约。ToolResult 不移动到 ToolRuntime，避免 AgentCore → ToolRuntime → AgentCore 循环；不创建重复声明。设计大纲是目标职责布局，不是要求将真实扩展文件删掉或建立未实现占位目录。历史 ADR 记录当时状态，本表与各目录 README 记录现状。

## Cleanup after layout alignment

See ADR 0021: PlatformKit/Audio now contains MicrophoneFrame and StreamingMonoPCMResampler instead of VoiceSegmenter/MonoPCMResampler. Gateway/Input has no VoiceInputSession or batch recognition entry points. VAD emits audio/end events only; test fixtures do not remain in production Agents.

## Qwen3.5 MLX adapter

✅ `ModelKit/Backends/MLX` implements the local language backend and tokenizer bridge; `ModelKit/Language/LLM/Qwen35` implements ChatCapability. Both are separate targets declared in the root project package. `Tests/Qwen35Tests` contains contract, tokenizer-reference and opt-in real-model evaluation tests. The root SDK target excludes concrete Qwen sources.


## Planned Agent communication directory

`MobileHarness/AgentCore/Bus/README.md` contains the detailed communication design and is excluded from the AgentCore Swift target. InternalSignalBus, typed ports, policy and bounded event tracking are implemented; request completion endpoints remain deferred. Gateway adapters are in Input/Output; AgentCore never imports Gateway.

## Fixed local model resources

✅ App uses Nemotron ASR and Qwen3.5-2B chat. ModelManager owns instances and lifecycle; adapters load local model directories directly. Development JSON profiles pin downloads without runtime manifests or per-file SHA checks. Audio8/ONNX runtime targets and Audio8/4B weights are absent; their download profiles remain available for comparison. Simulator ASR and chat are unavailable.
❌ Device retry stability and sustained memory/thermal acceptance require physical testing. See ADR 0031.

✅ Root Package.swift owns all project targets. Qwen35Tests and AgentModelEvaluationTests are separate root test targets. ModelKit has no nested package or in-module tests.

✅ ModelKit/Core owns AudioFrame/AudioFormat and ImageFrame with RGB or retained read-only native storage. ❌ Model-level video session contracts remain unimplemented.

✅ ModelKit/Vision/PoseCapability.swift belongs to base ModelKit; Vision/YOLO compiles separately as ModelKitYOLOPose. Core owns ImageFrame. Tests/YOLOPoseTests owns tests. ❌ Other Vision models remain unimplemented; camera/VisionPerception integration exists outside ModelKit.

✅ PlatformKit/Vision owns AVFoundation hardware; Experience/Camera owns the native preview bridge and controls; App/CameraCoordinator owns scene intent and lifecycle. App/PhotographySession adapts native frames for shared InputGateway → VisionPerception delivery and direct UI Action output.

✅ Agents/VisionPerception owns grayscale filtering, pose requests, typed observations and the v4 showPose Tool declaration; Actions/UI/ShowPose owns presentation side effects. Photographer has no runtime implementation until camera-motion policy is introduced. AgentCore ImageInput/PoseOverlay are dependency-free transport contracts; App adapts PlatformKit CameraFrame into a native ModelKit ImageFrame carried by an opaque AgentCore attachment; AgentCore imports neither Kit.

## Platform capability domains (2026-09-26)

✅ PlatformKit/Camera → Vision、Device → Core、ExternalDevice → Connectivity；Audio 保留共享采集/播放实现。一级按能力域组织，Core 为跨域契约例外，域内文件少时平铺。ModelKit 同样按能力组织，负责模型数据处理；PlatformKit 负责设备输入输出，App 负责桥接。类型名、模块依赖和运行契约不变。此条更新覆盖上面的历史迁移阶段描述。见 ADR 0039。
❌ 新设备实现和按设备拆分子目录只在实际需要时添加，不创建空实现。

## ADR 0040 additions

✅ AgentCore/Bus now compiles typed communication contracts, policy and bounded event transport. SpeechPerception owns LiveSpeechInput/VoiceActivitySegmenter; VisionPerception owns FrameChangeFilter and pose inference. ApplicationRuntime (in AgentBootstrap.swift) shares manager/bus/gateways before voice readiness. ❌ General request/reply and ReflexAgent are future work.
