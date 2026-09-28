# 实施计划

本页按日期保留实施里程碑和当时的验证记录；较早的“✅”描述反映该日期的实现，不代表当前模块仍按相同方式运行。当前能力以 [项目概览](../README.md) 和 [公开架构](Architecture.md) 为准，精确实现契约见[模块设计入口](../MobileHarness/README.md#part-ii--module-design)所链接的各模块 README。

## 当前待验收与后续方向

- ❌ 在 iPhone 上完成连续中英语音、真实 Kokoro 试听、音频路由切换、摄像头姿态与眼睛跟随的体验、延迟、内存和热状态验收；自动化测试及模拟器构建不能代替这些结果。
- ❌ 用真实第三方服务验证已接入的云聊天配置、切换和失败恢复。
- ❌ 在现有本地设置存储之外，按实际需求扩展持久化媒体与记忆、跨 Agent 请求/回复、更多感知能力及机器人动作；物理运动的限幅、失联停机和确认必须由设备侧承担。

## 历史实施计划与里程碑

依据原始技术方案与当前产品优先级，P1 首先接入必备模型与能力封装。模型通过统一能力协议解耦，Runtime 只同步补齐真实调用闭环所需的最小功能。详细目录与职责见 [ModelKit 设计](../MobileHarness/ModelKit/README.md)。本表为实施顺序，不是已完成清单。

| 阶段 | 范围 | 验收条件 |
| --- | --- | --- |
| P0 已建立 | SwiftUI 工程、六个 Package 模块、演示 Agent、双网关、工具回路、CI 与规范 | 核心测试、模拟器构建和启动；真机与完整 UI 验收另行记录 |
| P1 Models / Capabilities | ASR、TTS、一个本地小型 LLM、JEV；模型契约、制品、管理器和最小调度；语音闭环所需平台封装 | 真机加载/预热/生成/取消/卸载；换 provider 不改 Agent；语音闭环；权限拒绝与资源不足可恢复 |
| P2 Runtime / Routing | Agent 工厂、restart、完整 pause/resume、Tool 超时、完整 Action Markup parser、混合路由增强 | 并行 Agent 失败隔离；无残留任务；半截标签/非法输出/重启恢复；高频输入有界 |
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

✅ 权威设计链接更新；Actions/UI、Speech/Speak、ActionPath、AgentLifecycle 对齐；独立 ActionRuntime、Tools/System 与 ToolExecutor；ChannelParser/Channel 职责拆分；Package 和 Xcode 引用同步。当前目录映射见 [MobileHarness/README.md 的项目结构](../MobileHarness/README.md#project-structure)；原始决策见 ADR 0020。

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

✅ Swift/Python parity passed for ten complete prompts. Local real-model generation and cancellation/unload/reload checks passed. Device experiment artifacts were stored in local, unversioned `output/qwen35-mlx-2026-09-25`; [ADR 0027](adr/0027-qwen35-mlx-chat.md) summarizes the dated limitations without treating that path as a public report.

❌ Long-running thermal/memory measurements, complete microphone/ASR/TTS coexistence acceptance, reliable constrained XML generation and vision input remain outstanding.

## Function Token terminology (2026-09-25)

✅ FunctionTokenParser parses mixed text/XML protocol output; AgentGenerator resolves ActionCalls. AgentOutput.actionCall and OutputKind.actionCall classify Action invocations. ToolCall represents the separate native tool protocol. The canonical definitions are in MobileHarness/AgentCore/Generation/README.md and AgentCore/Output/README.md.

## Inter-Agent communication

✅ High-level architecture and detailed algorithms are specified in section 32 and AgentCore/Communication/README.md.

✅ JSON v4, typed event contracts, static subscriptions/direct sends, bounded state/discrete delivery and lifecycle fencing are implemented by ADR 0040. ❌ Request/reply completion slots and generic AgentContext supervision remain deferred.

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

✅ YOLOv8n Pose model-layer integration: bounded RGB transport, separate Core ML adapter, COCO-17 decoding, NMS, coordinate restoration and shared manager registration. ❌ Camera/Agent flow, s/m variants, human-image accuracy and iPhone performance acceptance remain P3 work. See ADR 0035.

Validation (2026-09-26): `scripts/check.sh` passed with full Xcode selected and YOLO_POSE_MODEL_ROOT enabled, including all four YOLO tests and default pose binding coverage. `scripts/build-ios.sh` passed all four simulator schemes. Real model smoke exercised blank-image inference, unload/reload and shutdown rejection on Mac; human-image accuracy and iPhone runtime remain unverified. Other existing opt-in model evaluations remained skipped.

✅ Preview-only camera UI: default front camera on normal foreground startup, front/back selection, on/off, full-screen dimmed background, permission recovery and inactive/background stop. ❌ Camera frame routing to Agent/YOLO and physical-device camera/audio/thermal acceptance remain outstanding.

Validation (2026-09-26): root scripts/check.sh passed; all four scripts/build-ios.sh simulator schemes passed; the physical MobileHarness Debug target compiled without signing. Simulator launch confirmed camera controls render during model preparation and the system camera permission prompt appears. The simulator has no physical camera and lacks voice model resources, so live video, front/back switching, camera/voice coexistence and ready-conversation visual acceptance still require an iPhone. No physical device installation was performed.

✅ At this milestone, the first P3 camera perception flow used configurable grayscale thresholds, latest-only Photographer pose inference, a shared model provider and Action-delivered skeleton UI. ADR 0041 later moved inference and skeleton display to VisionPerception and removed Photographer from the App. ❌ Robot arm motion, composition policy, tracking IDs and physical-device performance/accuracy acceptance.

Validation (2026-09-26): final root scripts/check.sh passed, including 66 IntegrationTests and shared .pose provider identity. A separate full check with YOLO_POSE_MODEL_ROOT enabled passed real Core ML blank-image inference, unload/reload and shutdown checks. All four simulator schemes and the unsigned physical MobileHarness Debug build passed. Inspected the final device App: Photographer.agent.json matches source, pinned YOLO weight bytes match, and the AGPL license is present. An old generated Agent bundle was invalidated so the new configuration was recopied. No physical camera/phone installation or human-pose alignment/accuracy/thermal acceptance is claimed.

✅ Pose CPU preprocessing/postprocessing optimization implemented with native vImage, shared layout, buffer reuse and bulk tensor reads. ❌ Optimized iPhone FPS, latency, thermal behavior and resampling accuracy require a new physical-device acceptance run.

✅ Native Vision/CPU+ANE YOLO baseline implemented, with bounded native lifetimes, gray-only Gateway admission and retained RGB/vImage comparison path. ❌ iPhone profiling, human-pose alignment/accuracy, pool/thermal stress, model-integrated postprocessing and multi-model sharing remain pending.

✅ YOLO26n-Pose directly replaces YOLOv8, including pinned provisioning, exclusive default binding and end-to-end output decoder. ❌ New-model phone accuracy/latency and thermal validation remain pending; historical benchmarks are not carried over.

## PlatformKit capability domains (2026-09-26)

✅ Audio/Vision/Connectivity domain grouping and Core shared contracts; source paths, SwiftPM README exclusions and Xcode navigation updated. ModelKit handles model data processing; PlatformKit handles device input/output. Runtime APIs and ownership are unchanged.
❌ Concrete external-device adapters and further domain expansion await actual requirements. See ADR 0039.

Validation (2026-09-26): root scripts/check.sh passed, including 69 IntegrationTests; all four scripts/build-ios.sh simulator schemes passed. Every PlatformKit source and README resolves in Xcode navigation. No new device installation or physical-device acceptance was performed.

## Capability ownership documentation audit (2026-09-26)

✅ Current entry, architecture, repository layout, contribution guidance and App/Gateway/Actions/Experience/model READMEs distinguish PlatformKit device I/O from ModelKit processing. Stale image/camera status and App-owned model registration descriptions were corrected against current code. Historical ADRs, validation evidence and original design sources are preserved.
❌ No new runtime behavior or physical-device acceptance is implied by this documentation update.




## Shared perception and pure Gateway (ADR 0040)

✅ SpeechPerception owns ASR/VAD; VisionPerception owns image-content filtering and shared YOLO inference. At this milestone, Photographer consumed poses for UI policy; ADR 0041 later moved skeleton display into VisionPerception and removed that runtime. AgentCore defines transport-only audio and typed observations. Gateway imports no model/platform capability module.
✅ Shared App communication assembly, JSON v4 permissions/subscriptions, directed events, bounded latest-state/discrete lanes, monotonic admission deadlines, per-target receipts and independent voice/camera cleanup.
❌ Device continuous voice/camera behavior and latency/thermal acceptance remain pending. Future face/depth/tracking/ReflexAgent work requires separate sampling and control-arbitration design; no robot safety or motion behavior was added.

Validation (2026-09-26): final scripts/check.sh passed, including 79 IntegrationTests, configuration and module-boundary checks. All four scripts/build-ios.sh simulator schemes passed; MobileHarnessSimulator was rebuilt after the final capture-gating fix. The unsigned MobileHarness device target built successfully. All four packaged Agent JSON resources are v4 and byte-identical to source. Original Technical_Design.docx is unchanged. Optional real-model evaluations were not enabled; no phone installation or continuous physical audio/camera/thermal acceptance was performed.

✅ 识别字幕行为统一：SpeechPerception 配置 UI.setTranscript，partial 更新和 final/空识别后的清空通过 Action 执行；保留共享转写 Signal。❌ 真机连续识别字幕时序及压力验收待完成。

✅ Skeleton visualization now belongs to VisionPerception: JSON Action registration, bounded projection and Action/control output. Shared pose publication remains available without requiring a subscriber. ❌ Photographer camera-motion policy is not implemented; its former display-only runtime was removed. See ADR 0041.

Validation (2026-09-26): final root checks passed, including 80 IntegrationTests and the no-subscriber/two-subscriber camera cases. All four simulator schemes and the unsigned physical Release target built successfully. Packaged VisionPerception JSON matches source; no Photographer JSON remains in the device App. No installation or physical-device acceptance was performed for this change.

✅ UI 行为统一：SpeechPerception 通过 Action 更新字幕/识别阶段；Assistant 通过 Action 清除表情/回复；移除 speech.phase 的 UI 旁路，补充 Agent 依赖检查。❌ 真机交互时序验收待完成。

✅ UI.showPose moved from Action to an explicitly registered Void Tool. No Channel scheduling or ToolResult feedback; bounded output, session/sequence validation and propagated failures remain. ❌ Physical-device latency acceptance is pending. See ADR 0042.

Validation: root scripts/check.sh passed (82 IntegrationTests), all four simulator schemes passed, and the unsigned physical Release target built. The bundled VisionPerception JSON matches the Tool-only source declaration. No phone installation or device latency measurement was performed.

✅ 对话展示按轮次管理：新轮一次清理、final 封闭识别、旧轮/旧序号拒绝、回复保留、停止清空。❌ 真机字幕/播放时序和动画验收待完成。

✅ High-priority visual freshness fixes: bounded independent publication, latest-only skeleton output and optional maximum refresh interval (App 100 ms). ❌ Device latency/thermal measurement and actual Photographer motion control remain pending. See ADR 0044.

Validation (2026-09-26): root checks passed, including 86 IntegrationTests; all four simulator schemes and the unsigned physical Release build passed. No phone installation or physical-device performance measurement was performed.

✅ Product UI refinement: face-proportioned procedural eyes, below-island violet reply spectrum and bottom blue microphone spectrum. Hann-windowed FFT and render-cursor synchronization replace synthetic waves. ❌ Physical-device spectral readability, route-dependent acoustic latency and sustained power acceptance remain pending. See ADR 0045.

✅ Procedural eye expression system: semantic emotions replace emoji throughout the presentation chain; stable paths and damped interpolation handle interrupted transitions. Sad/scared/thinking/playful presets are available. ❌ Complex authored performance sequences, real tracking and measured device animation performance remain pending. See ADR 0046.

## Explicit input routing cleanup (ADR 0047)

✅ Removed SignalRouter/LogicRouter and the submit fallback; migrated ToolResult delivery and tests to publish/send. Static-policy tests cover unavailable-target isolation, missing policy/subscribers and directed input validation. Package and Xcode directory references are updated.
❌ Dynamic routing/subscriptions and additional transport guarantees remain outside this cleanup.

Validation (2026-09-27): scripts/check.sh passed with full Xcode selected, including 92 IntegrationTests; scripts/build-ios.sh passed all four unsigned simulator schemes. No physical-device validation was performed.

## Direct signal admission (ADR 0048)

✅ Removed InternalSignalBus, transport queues/workers, timeout races, duplicate caches and communication session lifecycle. OutputGateway selects recipients and directly calls InputGateway; external and internal calls share bounded structured admission. Agent inboxes retain buffering, state policy and accepted-work cleanup. Receipts report admission; deadlines check freshness before receive. Action Channel queues are unchanged.
❌ No concurrent-delivery FIFO, dynamic subscription, automatic retry or hard-real-time device guarantee is introduced. Remote transport remains future work and does not inherently require a broker.

Verified (2026-09-27): scripts/check.sh passed, including 92 IntegrationTests; scripts/build-ios.sh passed all four unsigned simulator schemes using full Xcode. Optional real-model evaluations and physical-device acceptance were not performed.


## 眼睛跟随（2026-09-28）

✅ 新增 UI.moveEyes Action；感知层复用 YOLO Pose 脸部点位完成目标选择、短暂丢失保持、回正和自适应平滑，前摄镜像、相机会话隔离以及启动页/会话页连续动画已接入。❌ 真机跟随观感、多人交叉、遮挡及长期运行功耗待体验验收。见 ADR 0049。

## Kokoro 默认语音替换（2026-09-28）

✅ 复用现有 ModelKitKokoro 三图推理，将 ModelKitDefaults 的 synthesis 默认切换为 Kokoro，并移除生产 Apple speech 注册。Assistant 请求简短美式英语，Speech Action 默认 en-US；诊断与对话共享 manager/provider。见 ADR 0050。

❌ 中文前处理与中文音色、模型输出语言遵循、真实 iPhone 试听及持续运行验收仍待完成。历史系统中文 TTS 记录不代表当前默认行为。

✅ 本轮复验：根检查、四个模拟器 scheme 和五项 Kokoro Release 测试（含真实 Mac 推理）全部通过；3.375 秒固定英语音频合成约 1.07–1.34 秒。具体边界见 [Kokoro 验证](Kokoro-Validation.md)。

## Third-party cloud chat (2026-09-28)

✅ OpenAI-compatible text chat adapter, configurable Base URL/key/model, shared capability/session/lifecycle and explicit Defaults selection. Bounded SSE, cancellation, sanitized errors and offline protocol tests are included. See ADR 0051.
❌ Live-provider/device acceptance, cloud speech/vision and credential settings UI remain pending.

## Kokoro Core ML 中英双语（2026-09-28，取代英语单语默认）

✅ ModelKitKokoro 改用独立 ModelKitFluidAudio 后端：七阶段 Core ML、本地英文词典、中文数值/分词/声调/多音字处理。固定开发下载配置，App 只读本地资源；Assistant 恢复按用户语言回复，Speech locale=auto 保序合成中英混合文本。见 ADR 0052。

❌ 日法西语尚未接线；iOS 27 上游进程崩溃修复仍需真机长测，不能用 Mac 短测代替。中英分段使用不同音色，尚非统一音色混读。

✅ 双语替换复验：仓库检查、四个模拟器构建、真机目标无签名构建和五项 Release Kokoro 测试通过。真实 Mac 中英/混读/数字日期样例均生成音频；完整记录见 docs/Kokoro-Validation.md。

## Settings and live chat selection (2026-09-28)

✅ Top-right camera/settings toolbar, expandable camera controls, URL/key model discovery and picker, device-only Keychain and explicit chat replacement without process restart. See ADR 0053.
❌ Real provider credentials and physical-device UI/network acceptance remain pending.

Settings validation: root checks and nine cloud tests passed; all four simulator schemes passed. Visual automation timed out and live-provider/device acceptance remains pending.

✅ Standalone settings list → cloud LLM form, persisted cloud/local switch retaining credentials, explicit URL/key paste controls and navigation-stable runtime ownership. ❌ Physical-device interaction acceptance pending.

✅ 回复进入 TTS 前的分段已合并短逗号分句，使用句末、软长度、XML 边界和生成结束规则，并覆盖碎片边界一致性测试。❌ 真机韵律/停顿验收仍待完成。

## 独立合成 Agent（ADR 0055）

✅ 定向文本请求、串行合成、多来源所有权、按 ID 播放及内存缓存过期已接入，取代 Actions 内预合成和 Channel 优先级重排。✅ 仓库完整检查通过（108 项集成测试），四个 iOS 模拟器构建目标通过。❌ 可选真实模型评估未启用，本轮未安装真机，试听、Bluetooth 和持续运行验收待完成。

✅ 已移除旧 Action 准备协议和 Gateway 准备调用；缓存目录归属已由 ADR 0056 解决。❌ 真机验收仍待完成。当前行为细节见 [合成 Agent](../MobileHarness/Agents/SpeechSynthesis/README.md)、[播放 Action](../MobileHarness/Actions/Speech/README.md) 和 [音频缓存](../MobileHarness/Storage/Audio/README.md)。

## 共享存储里程碑（ADR 0056）

✅ Storage 与 StorageAudio target 已接入，旧 SpeechRuntime 已移除；迁移后的仓库检查和四个 iOS 模拟器构建目标通过。当前技术契约只在 [Storage](../MobileHarness/Storage/README.md) 与 [StorageAudio](../MobileHarness/Storage/Audio/README.md) 维护。❌ 真机语音验收、可淘汰磁盘缓存、持久化文件与记忆记录仍待完成。

### Local settings persistence and cache synchronization (2026-09-28)

✅ Storage now supports bounded durable documents, read-through/write-through caching, explicit refresh and revision conflicts. App settings migrate from the legacy Keychain record to a sandbox document with device-local credential references. ❌ Cross-device sync, general media persistence and device migration acceptance remain pending. See [ADR 0057](adr/0057-local-settings-storage.md).

Validation: `scripts/check.sh` passed, including 114 IntegrationTests and four local-document synchronization tests. `scripts/build-ios.sh` passed all four simulator schemes. Device Keychain migration, live cloud requests and phone installation were not exercised in this change.


## MOSS-TTS-Nano default synthesis (ADR 0058)

✅ Default registration, local provisioning, bounded streaming synthesis, Chinese/English preset voices and MOSS diagnostics replace Kokoro after repeated iPhone crashes. No automatic fallback. ❌ Sustained iPhone 17 Pro/iOS 27 stability, cold-start latency across conditions, Chinese number/date pronunciation and continuous speech acceptance remain pending.

✅ MOSS replacement checks: repository checks with real Mac synthesis, all four simulator schemes and signed physical Release build passed. Installed on iPhone 17 Pro; two short mixed-language synthesis runs completed without process termination. Cold prediction latency prompted explicit startup warmup; the final revision also completed a device diagnostic (loading/warmup 0.75 s, first PCM 0.04 s, total 1.85 s for 5.04 s audio, thermal nominal). ❌ Audible quality and sustained full-conversation acceptance remain pending; see [MOSS validation](Moss-Validation.md).

### Cloud settings input defaults (2026-09-28)

✅ Optional Key, blank URL fallback to the official OpenAI endpoint, visible default chat model and filtered model discovery are implemented. ❌ Live provider and device UI acceptance remain pending.

✅ MOSS follow-up crash logs identify a MainActor isolation assertion in the AppleAudioIO mixer tap, corrected with an explicitly Sendable callback. Diagnostics now exercise production playback; see [MOSS validation](Moss-Validation.md) for evidence and device acceptance.

✅ Following MOSS playback buffer overflow, the production per-handle PCM cache was increased from 2 MiB to 8 MiB at the user’s request, matching the synthesis output limit. ❌ This does not add backpressure or remove long-reply limits; sustained conversation acceptance remains pending.

## LLM 原始输出测试（2026-09-28）

✅ 设置新增独立 LLM 测试页：复用已保存模型、Assistant 提示词和 JSON，展示完整接收原文、分片、结束原因、解析错误及解析出的 Action/Channel，可显式导出。解析失败继续收集；取消、传输失败、token 上限和保留上限均明确标记。生产 Agent/Gateway 契约未改变。

❌ 真机交互、真实本地/云模型输出验收以及实际 Channel 执行时序跟踪仍待完成。此页是单轮无副作用测试，不重放已有语音会话；详见 [Diagnostics](../MobileHarness/Experience/Diagnostics/README.md)。
