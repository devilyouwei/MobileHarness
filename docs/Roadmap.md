# 实施计划

依据原始技术方案与当前产品优先级，P1 首先接入必备模型与能力封装。模型通过统一能力协议解耦，Runtime 只同步补齐真实调用闭环所需的最小功能。详细目录与职责见 [ModelKit 设计](../MobileHarness/ModelKit/README.md)。本表为实施顺序，不是已完成清单。

| 阶段 | 范围 | 验收条件 |
| --- | --- | --- |
| P0 已建立 | SwiftUI 工程、六个 Package 模块、演示 Agent、双网关、工具回路、CI 与规范 | 核心测试、模拟器构建和启动；真机与完整 UI 验收另行记录 |
| P1 Models / Capabilities | ASR、TTS、一个本地小型 LLM、JEV；模型契约、制品、管理器和最小调度；语音闭环所需平台封装 | 真机加载/预热/生成/取消/卸载；换 provider 不改 Agent；语音闭环；权限拒绝与资源不足可恢复 |
| P2 Runtime / Routing | Agent 工厂、restart、完整 pause/resume、Tool 超时、EventBus、完整 Action Markup parser、混合路由增强 | 并行 Agent 失败隔离；无残留任务；半截标签/非法输出/重启恢复；高频输入有界 |
| P3 Perception / Agents | VLM、检测、关键点、embedding 按场景接入；Camera、Photography、Tracking、Perception、Media | 摄像头 → 模型 → 事件 → Agent → 动作闭环；测量延迟、内存、耗电和热状态 |
| P4 Robot | Bluetooth / Local Network、配对、动作参数校验、watchdog、急停 | 先仿真再真机；断连与 App 挂起自动停机；限幅；不重放过期动作 |

P1 拆分为契约与测试替身、首个真实 LLM、语音闭环、JEV 与资源策略四步。ASR/TTS 可先采用系统能力 provider，JEV 可复用小型 LLM；不要求每种能力都单独下载一个模型，也不要求三个后端同时落地。

Core ML、Core AI、MLX 均属于方案中的候选后端。Core AI 已有 [Apple 官方公开框架](https://developer.apple.com/core-ai/)，具体模型制品、API availability 与目标硬件仍需在接入时核实。App 不做训练或格式转换，权重不入 Git。

P1.1 能力 SDK 与组装边界已实现：ModelKit 不依赖业务层，提供 chat/transcribe/synthesize/judge 接口、可组合依赖、输入校验、单请求取消与有界流；ModelKitRuntime 提供应用组装专用注册/绑定，配套测试替身只位于 Tests。后续 Nemotron 已补齐首个具体模型、制品校验与最小调度，仍不代表 P1 整体完成。

系统语音路径已先行实现：独立 AppleSpeech adapter、RequestGateway ASR、ResponseGateway TTS、PlatformKit 音频与基础 VAD，以及固定回复 UI 闭环。系统中文 TTS 可在本机实际合成，真实麦克风/端侧 ASR 需按 [语音验收说明](Voice.md) 在目标真机完成验证。当前为轮流说话，不支持播放中抢话或后台录音。

2026-09-23：为模拟器调试，App 经用户授权开启可关闭的 Apple 联网 ASR；后续本地 ASR 仍通过相同能力协议接入。联网模式不能代替真机离线验收，也不保证模拟器的 Apple 识别服务可用。

目录已按 Tech_Design.md 第 16 节迁至 MobileHarness/ 与根目录 Tests/；App 装配、Conversation ViewModel、Gateway Request/Response、AgentCore Contracts/Runtime/Protocol 已分开。根 Package.swift 仅为同一源码提供测试与模块边界。保留此前确认的 ModelKit 零业务依赖约束，详见 ADR 0005。目录对齐不代表 M0 已全部实现：增量 Markup parser、完整 restart/generation、macOS App target 和连续语音稳定性验收仍待完成。

首个独立本地模型 Nemotron 流式 ASR 已实现并下载：CoreAI 后端、流式 mel/RNNT、本地模型资源加载、单模型 lease 和最小 admission 已落地。现已通过 capability 注入 Gateway/App，详见 ADR 0007。Mac 合成中英文语音推理与不同分片一致性已验证；iOS 真机运行、真实录音 WER/延迟/内存测试、更多硬件制品和完整跨模型调度仍待完成。模型层目录以 ADR 0006 为准。

App ASR 已切换为 Nemotron，保留系统 TTS 与固定回复；新增有界 16 kHz 重采样、真机模型打包及录音前加载。连续麦克风实时 partial UI 已实现（见下文）；真机连续运行和资源压力验收仍待完成。

Silero Core ML VAD 已实现并用于 App 输入分段：标准 VoiceActivityCapability、独立状态会话、连续重采样与概率分段策略已落地。真实模型 Mac 合成语音、分片一致性和 Silero→Nemotron 组合已验证；手机噪声环境、连续对话、功耗/热状态仍待验收。

语音编排优化：实现尾音暂存裁剪、带结束原因的分段、长句持续收音及有界串行识别、结束提交与立即取消、旧会话清理屏障及分段诊断日志。契约见 ADR 0011；连续真机语音和分段边界准确率待验收。

语音页面已改为纯黑圆环与字幕：整圆点击开关、首次预热旋转呼吸、实际麦克风/TTS 音量驱动的蓝紫动效、增量字幕淡入。LiveSpeechInput 在 VAD 起音后实时送入 Nemotron，partial 仅预览，端点后合并 final 提交 Agent。替身测试验证实时预览、修订顺序及取消后复用，VAD 测试验证流式与封段 PCM 一致；真机动态观感、延迟和连续对话仍需实录验收。契约见 ADR 0012。

## 分句行为输出与 Actions（2026-09-24）

Assistant 的回复改为边生成边分句，短句分别输出 say/print FunctionToken，正常结束补发尾句。共享行为实现集中到 `Actions`，AgentDescriptor 只登记简单标签到模块函数路径的映射；Gateway 验证和解析后使用显式 handler 目录执行，不增加 Agent 对具体行为或平台的依赖。上述调整取代整段回复交给 Gateway 做 TTS 的阶段实现，见 [ADR 0015](adr/0015-function-actions.md)。

动作执行采用每模块有界 FIFO、跨模块并行；Speech.say 等到真实播放完成才接下一句，Display.print 可同时追加字幕。本轮生成结束并等待已接纳动作全部完成后才恢复聆听。停止取消生成、排队动作和播放，保留模型卸载及旧会话清理屏障。

本阶段验收覆盖分句、路径映射、模块顺序/并行、队列溢出、取消和完成屏障；真机首句延迟、连续播放衔接及中文质量仍需实测。XML / GhostShell parser 等待完整方案，不把当前分句器视为已完成 Action Markup。全局模型预算、持久动作幂等和机器人执行安全仍未实现。

本轮逐句 Actions 验证：根检查通过（35 项集成测试），模拟器五个 scheme 与签名真机 App 编译通过；手机实际语音体验待测试。

## Kokoro 本地 TTS 验证（2026-09-24）

按用户指定的 Kokoro-82M-CoreAI 制品新增独立 capability、固定版本下载/校验、CPU 图与宿主 DSP、英语输入限制、有界 PCM 和取消/卸载，以及 KokoroValidation 真机试听入口。保留当前中文对话的系统 TTS，未宣称此英语导出具备多语言能力。验收记录见 docs/Kokoro-Validation.md；真机自然度、首段、内存和持续热状态仍需实际设备测量。契约见 ADR 0016。

Kokoro 验证结果：5 项测试（含真实 Mac 推理）通过，根检查和五个模拟器构建通过，真机 Release 签名构建通过。iPhone 安装两次遇到连接中断，真实手机推理/音质/内存/热验收未完成。Mac 缓存加载 0.337 秒，3.375 秒固定英语音频合成约 1.04–1.51 秒；不当作手机指标。

## 新设计迁移第一阶段：App / Experience / Gateway（2026-09-24）

目标设计切换为 MobileHarness/README.md。本阶段迁移 Gateway/Input、Output，拆分 Validation/Routing/Dispatch；提取 Experience/Components，集中 App 的具体模型装配，并为本阶段所有目录补齐 ✅/❌ README。具体过渡边界见 [ADR 0017](adr/0017-entry-gateway-migration.md)。

AgentCore 的 Signal、Agent 内解析与完整 ActionCall、Output 的 GhostShell/Channel 调度、独立 ActionRuntime 和动作结果回流仍未迁移。本阶段保留现有语音、工具和动作运行行为，不将目录对齐等同于新设计全部实现。

本轮自动验证通过：核心检查（含 35 项集成测试）、五个模拟器 scheme 构建、真机目标 Debug 无签名编译；目录 README 与工程引用核对通过。默认跳过的真实模型/音频测试以及手机连续语音人工回归不计为已验收，详见 ADR 0017。

## 新设计迁移第二阶段：AgentCore / Agents / 共享输出解析（2026-09-24）

✅ AgentCore 拆为根层协议、Capability、Generation、Output、Runtime；Assistant 使用共享流式 FunctionTokenParser/AgentGenerator，文本映射为 say/print，动作自闭，Channel 开闭与嵌套恢复；Agent 内解析路径，Gateway 仅验证/分发已解析 ActionCall/ToolCall。

✅ 独立 ToolCallParser 完整原生调用解析；System.runtimeInfo 工具回路保留。ChannelScheduler 从 Actions 迁至 Gateway，按有效 Channel FIFO 并保留设备模块互斥、容量、取消与完成屏障。各目录 README 补齐 ✅/❌，解析器、能力目录、运行时和调度器有 Mermaid 设计图。

❌ 模型原生 tool delta 接入、完整 JSON Schema、统一 Signal、通用 AgentRuntime/StateStore/Bus、restart/健康监督、强类型运行通知、ActionResult、优先级/抢占。细节与验证见 [ADR 0018](adr/0018-agent-protocols.md)。

第二阶段验证：最终核心检查通过，包含 46 项集成测试；五个模拟器构建与真机 Debug 无签名编译通过。解析器/调度器边界与新旧语音回归已覆盖；默认跳过的真实模型测试、真机连续语音及模型 XML 指令遵循质量仍待实测。

## Agent 配置与开发规范（2026-09-24）

✅ Assistant 的 action/tool/channel/textActions 从独立 Assistant.agent.plist 加载；统一 v1 格式和完整 Agent 开发规范集中于 Agents/README.md，AGENTS.md 指向该标准。共享配置校验器、包资源加载、可抛错初始化和 App 配置错误展示已接入。默认语音行为和 handler 装配保持原样。

❌ 配置热更新、远程配置、完整 JSON Schema、完整启动期 handler 路径核对。详见 ADR 0019。

配置迁移验证通过：50 项集成测试、五个模拟器构建、真机 Debug 无签名构建；实际 App 包资源与源 plist 一致。真实麦克风与连续语音体验未在本轮重新验收。

## 正式 README 目录与命名对齐（2026-09-24）

✅ 权威设计链接更新；Actions/UI、Speech/Speak、ActionPath、AgentLifecycle 对齐；独立 ActionRuntime、Tools/System 与 ToolExecutor；ChannelParser/Channel 职责拆分；Package 和 Xcode 引用同步。完整核对见 Repository-Structure.md 与 ADR 0020。

❌ 目标大纲中的未来模块仍按实际需求实现；共享契约及根测试目录例外已说明。运行行为保留现有模型 alias、默认 Channel、FIFO/资源互斥和工具回流。

本轮验证：最终 scripts/check.sh 通过（含 50 项集成测试），五个模拟器 scheme 构建与 MobileHarness 真机目标 Debug 无签名编译通过；迁移目录的 Xcode 导航引用完整且无失效路径。默认跳过的真实模型/音频测试与真实手机连续语音体验不计为本轮已验收。

## Obsolete code cleanup (2026-09-24)

✅ Removed the old energy VAD, batch resampler/recognition session, unused UI controls/state and Assistant fixed-reply fallback. Migrated tests to live streams and retained sample-order, endpoint, cancellation and capacity checks. See ADR 0021.

❌ Real-device continuous microphone/playback acceptance is not included in this cleanup.

Cleanup validation: final scripts/check.sh passed, including 47 integration tests and 10 Silero/boundary tests (one opt-in real-model case skipped). Five simulator schemes and the device App Debug build without signing passed. Five real-model/audio cases remain opt-in and were not exercised; physical device voice acceptance is pending. Xcode file references resolve and removed production APIs have no remaining Swift callers.

## Action function cohesion (2026-09-24)

✅ Removed TextAction; speak and print independently own text validation. Existing TTS output checks, cleanup, presentation error propagation and cancellation remain local. Added direct-call parameter boundary tests. No new fallback behavior or invocation-contract changes.

## JSON capability configuration (2026-09-24)

✅ Migrated Assistant and the resource loader to JSON v2; added parameter documentation, structured examples, output descriptions and notes with strict bounded validation. Registration metadata survives loading.

❌ New metadata prompt rendering, full JSON Schema, automatic conversion/default injection, and hot reload remain unimplemented. Existing invocation behavior is preserved.

JSON migration validation: final core checks passed, including 51 integration tests; five simulator schemes and unsigned device Debug compilation passed. The JSON resource in both App bundles matches source. Real-device voice behavior and new metadata prompt rendering were not exercised.

## Capability doc and visibility (2026-09-24)

✅ JSON v3 merges capability usage guidance into doc, changes Action examples to XML/natural-text strings and filters hidden registrations from model context. Assistant say/print are hidden and automatic text mapping remains unchanged. Visible docs/examples are now included in prompts.

❌ Model-native tool streaming and execution-time semantic validation from configuration remain outside this change.

JSON v3 validation: 53 integration tests and core checks passed. Five simulator schemes passed; the simulator App was rebuilt after correcting invalid JSON text. Device Debug compilation without signing passed. Both App JSON resources match source. No installation or physical voice acceptance was performed.

## Orb expressions (2026-09-25)

✅ Added UI.express with six finite emotions and retained smile. App routes expressions separately from captions; the voice circle shows a large emoji with spring entry, glow and reduced-motion fades. New speech or session stop clears the expression. See ADR 0024.

❌ Physical-device visual and conversational acceptance remains pending.

Expression validation: core checks passed, including 55 integration tests; five simulator schemes and unsigned device Debug compilation passed. Physical-device visual acceptance and installation were not performed.

## Unified expression Action (2026-09-25)

✅ Removed UI.smile and its Agent alias/shortcut. UI.express now accepts smile alongside the six existing emotions; JSON documentation, App bindings and protocol fixtures use the same function. Historical model-quality evidence is unchanged. See ADR 0025.

❌ Real-model quality with the simplified registration remains to be measured; this change does not claim to fix the identified template or model issues.

Unified-expression validation: root checks passed, including 56 integration tests; all five simulator schemes built successfully. No iPhone installation or new real-model quality evaluation was performed.

## Action-only system context (2026-09-25)

✅ Removed all native Tool Call declarations/docs/examples from the system prompt; only hidden=false Actions are concatenated. Tools remain registered and executable through existing routes.

❌ Native tool schema/delta integration and renewed real-model quality evaluation remain pending. See ADR 0026.

## Qwen3.5 MLX chat (2026-09-25)

✅ Added a separate Qwen35Chat adapter and MLX language backend; the physical app selects Qwen3.5-2B 4bit through the existing ChatCapability. Pinned model/dependency versions, local loading and resource/license staging are implemented.

✅ Swift/Python parity passed for ten complete prompts. Local real-model generation and cancellation/unload/reload checks passed. Device results and remaining acceptance limits are recorded in output/qwen35-mlx-2026-09-25. See ADR 0027.

❌ Long-running thermal/memory measurements, complete microphone/ASR/TTS coexistence acceptance, reliable constrained XML generation and vision input remain outstanding.

## Function Token terminology (2026-09-25)

✅ FunctionTokenParser parses mixed text/XML protocol output; AgentGenerator resolves ActionCalls. AgentOutput.actionCall and OutputKind.actionCall classify Action invocations. ToolCall represents the separate native tool protocol. The canonical definitions are in MobileHarness/AgentCore/Generation/README.md and AgentCore/Output/README.md.

## Inter-Agent communication

✅ High-level architecture and detailed algorithms are specified in section 32 and AgentCore/Bus/README.md.

❌ Implement typed contracts and a versioned communication policy, bounded Gateway-mediated event delivery, then request/reply completion slots, causal limits and lifecycle cancellation. Integrate AgentContext and two business handlers only after deterministic queue/deadline/race tests pass. Current JSON v3 and the running single-Assistant configuration remain unchanged.

Acceptance requires no blocked reply behind its waiting requester, no unbounded transport or control queue, explicit partial fan-out failure, stale-incarnation rejection and joined cleanup. Persistence, remote transport, automatic retry and streaming replies are outside initial scope.

## Channel lock

✅ Channel.swift defines ownership metadata and immutable-default unlocked state; scheduling behavior is unchanged. The technical design and Scheduling README specify exclusive control, atomic channel groups and physical-control boundaries.

❌ Implement validated runtime control ports and App-owned channel/resource policy before acquisition. Add takeover quiescence, dual admission/start enforcement, finite lease renewal/release, owner/session cleanup and control notifications. Physical domains require stop/hold acknowledgements and fencing across alternative channels and Tool routes. No robot hold behavior or lock guarantee is currently available.

## Reply retry stability

✅ Malformed-output recovery regression coverage; retry retains prepared providers instead of unloading/reloading weights. MLX reusable allocation cache is capped at 64 MiB.

❌ Confirm on iPhone that malformed output followed by retry and repeated explicit stop/reload stays stable. Device memory-pressure reports show pressure but do not establish MobileHarness termination causality.

## Shared ModelManager

✅ Unified registrations, typed get with deferred composition, shared provider identity, coalesced bounded backend loading, explicit load/warmup/unload/status/shutdown and retained-handle reload. Qwen, Nemotron, Silero, Kokoro and system speech participate through injected ModelContext/ModelResource. Voice stop and XML failures only cancel sessions.

✅ Tests cover construction and load reuse/retry, unload waiting, retained handles, shutdown cancellation and registration capacity. Simulator and device build results are validation evidence, not runtime acceptance.

❌ Timed idle eviction, total-memory/thermal budgets, waiting inference admission and sustained iPhone error/retry acceptance.

## Fixed local model resources

✅ App uses Nemotron ASR and Qwen3.5-2B chat. ModelManager owns instances and lifecycle; adapters load local model directories directly. Development JSON profiles pin downloads without runtime manifests or per-file SHA checks. Audio8/ONNX runtime targets and Audio8/4B weights are absent; their download profiles remain available for comparison. Simulator ASR and chat are unavailable.
❌ Device retry stability and sustained memory/thermal acceptance require physical testing. See ADR 0031.

✅ Fixed-resource validation: root checks, optional adapter tests, real Mac Qwen2B/Nemotron/Silero/Kokoro tests, all four simulator builds and signed physical App build pass. Packaged resources were inspected; the uncompressed Debug App is about 3.3 GiB. ❌ iPhone installation and sustained retry acceptance remain pending.

## ModelKit resource policy

✅ ModelManager.get is the sole acquisition API. ModelContext management uses ModelManagement SPI. Residency includes unmanaged and is distinct from capability availability. ModelKitDefaults configures the MLX cache explicitly; App forwards coalesced memory warnings; releaseWhenIdle entries evict only loaded resources without active work. OperationAdmission rejects concurrent backend operations without a queue. See docs/adr/0032-modelkit-admission-and-memory-policy.md for the contract.
❌ Timed eviction, measured cross-model memory budgets and physical-device pressure/retry acceptance.

✅ Qwen3.5-2B is the production chat model; Qwen4B remains a download-only comparison profile. Native CoreAI supports ASR and diagnostic TTS.

## ModelKit project boundary

✅ Root Package.swift declares all targets. ModelKit stays inside this project with no nested package and no dependency on business targets. Management and Backends separate lifecycle control from engine execution. All tests live under root Tests; application prompt evaluations are isolated in AgentModelEvaluationTests. scripts/check.sh enforces import/target boundaries and directory READMEs. See ADR 0033 for the contract.
❌ Independent SDK distribution and physical-device acceptance are outside this migration.

✅ ModelKit project-boundary migration validated: root checks, model-only real Qwen tests, the independent 30-record Agent evaluation, four simulator schemes and the signed physical App build pass. ❌ No iPhone installation or semantic-quality acceptance is claimed.

✅ AudioFrame.swift is part of ModelKit/Core. Core is the home for shared audio and future image/video contracts; platform I/O and model-specific processing remain separate. ❌ Image/video types are not implemented until needed.

✅ ModelKitDefaults owns fixed provider registration and default capability bindings. App supplies a resource root and retrieves interfaces with get(.chat) and the other capability keys. ModelKitRuntime remains adapter-independent. See [ADR 0034](adr/0034-modelkit-default-assembly.md).

✅ Default assembly validation passes root checks (including lazy assembly, shared identity and binding conflicts), four simulator schemes and the signed physical App build. ❌ Installation and iPhone runtime acceptance remain outstanding.

✅ ModelKitDefaults.manager(resources:) returns the process-wide manager. Concurrent calls share assembly and provider instances; conflicting resource roots fail. Construction/registration are assembly SPI. Each model admits one active operation, rejects overlap with inputBusy, and releases admission only after cleanup. Cross-model scheduling is not implemented.

✅ App startup sequentially prepares recognition, chat, VAD and system TTS before enabling conversation. Loading stages and explicit retry are presented without opening the microphone. ❌ Physical-device loading latency and startup interaction acceptance remain outstanding.
