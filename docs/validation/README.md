# 验证与验收资料


[ModelKit 模型目录与请求元数据](ModelKit-Model-Identity.md) 记录 Swift 回归、工程检查、构建及 Apple Intelligence 真机验收。

[Action 多轨道调度与 wait](Action-Multi-Channel-Wait.md)：自闭 `time` 延时、Skill 注册、教学迁移的自动化证据及未执行的真实模型/真机验收。
[wait 提示词真实模型评估](Wait-Prompt-Evaluation.md)：qwen3.8-max/flash 与 gpt-4.1 对 wait 作用域与延时 function token 的单轮语义评估、失败分析与局限。

[Xcode 工程配置清理](Xcode-Project-Cleanup.md)：工程结构、五个模拟器构建目标、资源验证及 SwiftPM 锁等待限制。

本目录保存验证方法和可追溯证据。报告必须区分替身测试、真实模型、构建、原生 UI 和物理设备，并保留日期、环境、版本、失败与未执行范围。历史报告中的“当前”“默认”“尚未接入”只对应当时版本，不是今天的配置或待办。

## 当前验收入口

[Signal 非 IPC 改造验证](Signal-Redesign-Validation.md)：外部监听、内部请求/事件、任务恢复与调用快照的工程检查、构建证据及验收限制。

[Tests 分层整理](Tests-Layering.md)：模块目录下的单元、集成与 UI 测试分类，混合文件拆分、无效通过修复和工程验证证据。

[全双工播放保护与 ASR 冷却](Full-Duplex-Playback-Admission.md)：短时 PCM 丢弃、播放态起声、增强时间对齐及自动化/真机验收边界。

[ReACT 回复字幕](ReACT-Reply-Captions.md)：工具结果续轮字幕、旧 Decision/取消轮次拒绝及构建与检查限制。

[Application localization](App-Localization.md) records automated, bundled-resource, and native Simulator evidence separately from device and model acceptance.

[Assistant 执行轮次结算](Assistant-Channel-Settlement.md) 记录相机 ReACT 拆批证据和缓冲回归。

[Action 执行反馈与打断续说](Action-Execution-Lifecycle.md) 记录逐项、逐轮和会话打断回报，以及实际 VAD 窗口和清理失败的验证。

[Writer 提示词与续写上下文](Writer-Resource-Organization.md) 记录模型请求、续写接纳、定向通信与资源打包的验证。

[语音感知单向通信](One-Way-Speech-Perception.md) 记录 VAD、ASR、关键词的 Gateway 发布、快停时序、布尔聆听与播放区间回归。

[ASR 用户输入通行](ASR-User-Input.md) 记录片段和最终文本路由、语音本地生命周期及验证范围。

[拍照倒计时与显式打开](Photo-Countdown-And-Explicit-Open.md)：单轮打开/话术/拍照、单次倒计时、参数校验及构建/设备验收边界。

[网页当前截图 State](Web-Screenshot-State.md)：单槽替换、scope、生命周期、共享请求附件、完整检查与原生/真机验收边界。

[Assistant 全双工与 Decision](Assistant-Full-Duplex.md)：整批输入、跨轮执行、分类回退、真实 D3 与音频/UI 验收边界。

[Assistant 内聚语音合成](Assistant-Owned-Speech.md)：内部 FIFO、会话隔离、停止清理、角色资源移除及构建/真机验收边界。

[BasicSkill 控制教学](BasicSkill-Control-Teaching.md)：六部分通用教学、九项动作效果、完整检查、资源打包和实模通过/失败边界。

[Skill 发现与能力拒绝教学](Skill-Discovery-Before-Denial.md)：加载前决策教学、浏览回归场景与当前工作区构建阻塞，区分静态检查与尚未执行的模型/设备验收。

| 文档 | 职责 |
| --- | --- |
| [Database 按表整理与日志清空](Database-Table-Ownership.md) | 早期 11 表整理记录，以及后续十表独立 Agent 重构、回归、构建与清洁安装证据。 |
| [Camera 会话图片缓存与多图浏览](Camera-Session-Gallery.md) | 会话短编号、20 张 FIFO、处置保留、历史隔离、浏览与关闭回归及真机验收边界。 |
| [可读预览编号与合并输入](Readable-Preview-Context.md) | 历史版本的持久编号、合并输入与安装证据；编号策略已由 Camera 会话方案替代。 |
| [预览照片历史读取](Preview-History-Images.md) | previewID 历史展示回归、缓存／已保存原图解析、过期提示及真机证据。
| [预览图片与多模态 State](Preview-Image-State.md) | 内存缓存、跨轮图片选择、请求附件和日志脱敏的自动验证及原生验收边界。
| [全局灵动岛](Global-In-App-Island.md) | 设置/记录/相册中的全局状态与展开偏好、导航及生命周期回归、原生界面验收限制。 |
| [原生音视频故障诊断](Native-Media-Failure-Diagnosis.md) | 保存照片后媒体服务重置的现场证据、错误保真回归及真机调查限制。 |
| [Writer 执行与续写生命周期](Writer-Execution-Lifetime.md) | 工具接纳后的续写权限、取消/清理并发回归、Simulator 构建与历史失败记录。 |
| [Writer 消息倒序与自动分页](Writer-Records-Descending-Scroll.md) | 两张列表的排序、末页、滚动加载与导航返回。 |
| [Writer 文件读取参数兼容](Writer-Read-Integer-Arguments.md) | 六条真机失败记录、Responses 参数回归和构建结果。 |
| [Writer 按 ID 直接打开和进入](Writer-Direct-Workspace-Access.md) | 真机调用调查、直接选择与无效 ID 回归。 |
| [Writer 精选事件播报](Writer-Selective-Assistant-Feedback.md) | 替身合成、授权播放、去重、后续模型上下文和设备验收边界。 |
| [Writer 工具与工作区身份](Writer-Workspace-Tools-and-Identity.md) | 工作区别名、参数恢复、SQLite 重置和模型首个工具验证。 |
| [Writer 重复创建与缺入口恢复](Writer-Create-Loop.md) | 真机 SQLite 调查、重复调用防重、缺入口修正与构建。 |
| [Writer Skill 统一注册与工作区切换](Writer-Skill-Registration-and-Switching.md) | 统一注册、叠加 Skill、编辑目标切换与失败恢复。 |
| [Writer 工具注册拆分](Writer-Tool-Separation.md) | 独立函数、参数校验、分域调用、历史与构建。 |
| [Writer 显式结束委托与通用作品打开](Writer-Explicit-Finish-and-Open.md) | 控制轮补交 finish、按选中 ID 单开和多开、独立失败以及构建证据。 |
| [Writer 与网页多窗口](Writer-and-Web-Multiwindow.md) | 真机 SQLite 只读调查、批量打开和定向换站回归、构建与验收范围。 |
| [WriterAgent](Writer-Agent.md) | 流式创作、后台任务、工作区回归及原生 WebKit 验证，区分真实模型和真机验收。 |
| [UI interaction paths audit](UI-Interaction-Paths-Audit.md) | Static routing and consistency audit of presentation-only, touch-business and voice-business interactions; deviations and validation limits. |
| [Container 状态与模型上下文](Container-State-Context.md) | 容器快照、Skill v3、StorageState移除、自动化证据及独立原生验收。 |
| [镜头切换准入](Camera-Control-Availability.md) | 全局模型准备与原生相机按钮解耦，状态回归及真机验收边界。 |
| [基础相册](Album.md) | App 收录、格式保持导入、独立系统导出、容量保护及删除恢复；真机验收与自动化区分。 |
| [多 Provider 管理](Provider-Management.md) | 多配置持久化、凭据清理及模拟器验证范围。 |
| [Gateway container](Gateway-Container.md) | App-owned Gateway lifetime, admission/cleanup regression, bounded diagnostic isolation and build evidence. |
| [Agent containers](Agent-Containers.md) | Root/role ownership, lifecycle regression, build evidence and independent native acceptance. |
| [Agents / Actions 组织整理](Agents-Actions-Organization.md) | 目录归属、共享机制与端点解耦的回归、模拟器编译和原工程文件协调限制。 |
| [外部输入直连 Container](Direct-Container-Input.md) | 直连迁移的自动检查、锁定依赖构建、设备修正版安装及尚未完成的原生／性能验收。 |
| [项目验证日志](Validation-History.md) | 按日期记录仓库检查、构建、部署、问题调查与验证结果；专项报告有详细数据时使用链接。 |
| [Qwen／GPT-4.1提示词回归](Qwen-Workflow-Regression.md) | 最新59场景Qwen三模型结果、GPT-4.1鉴权阻塞及历史协议样本；不等于物理设备验收。 |
| [千问提示词修订回归](Qwen-Prompt-Optimization.md) | 基于原始失败修订教学后的同用例对照，保留 pilot、完整运行及残留失败；不改执行权限。 |
| [连续动作提示词验证](Action-Sequence-Prompts.md) | 串行动作、组内语音/表情并行的生产示例与预算回归；包含 Flash/Max 三轮专项及完整原始数据，保留完整检查、构建与原生效果验收限制。 |
| [语音验收指南](Voice.md) | 当前可重复的语音体验检查步骤及记录要求，不固定某次模型默认或宣称已经通过。 |
| [NexArm 物理试验](NexArm_Physical_Acceptance.md) | 带日期的真实硬件调查和测量，限定 USB/BLE、设备、负载和观察范围。 |

## 专项历史报告

| 报告 | 证据范围 |
| --- | --- |
| [代码 README 验证摘录](Code-README-Validation-History.md) | 从代码目录迁出的测试、构建、安装与验收原文；保留原日期和限制，不作为当前通过状态。 |
| [MOSS](Moss-Validation.md) | 2026-09-28 的 Mac/短时 iPhone 合成、播放故障及容量调整记录。 |
| [Nemotron](Nemotron-Validation.md) | 早期 CoreAI 接入与 2026-10-03 Core ML 制品替换，分阶段解释。 |
| [Silero](Silero-Validation.md) | 2026-09-23 的真实 VAD、分片及识别组合验证。 |
| [Kokoro](Kokoro-Validation.md) | CoreAI 英语与 Core ML 中英实现的旧测试和未完成验收；不代表当前默认。 |
| [Audio8](Audio8-Validation.md) | 已移除适配器的历史验证，旧下载/测试入口不保证仍可执行。 |
| [初始化](Bootstrap-Validation.md) | 2026-09-22 工具链、最初测试与环境限制快照。 |

## 证据与当前契约

模型选择、默认值、资源安装、超时和容量由 [ModelKit](../../MobileHarness/ModelKit/README.md)、[App](../../MobileHarness/App/README.md) 与所属模块 README 维护，报告不重复一份会漂移的当前配置。执行旧复现步骤前核对现有源码、脚本和制品版本；文中命令以仓库根目录为工作目录。

项目日志记录跨模块检查的经过，专项报告保留模型/设备实验的详细样本和测量。相同实验通过链接复用，不能把多个报告中的相同运行合计为更多次验证。历史失败不删除，新的成功也不追溯改写旧结果。

[当前验收方向](../Roadmap.md#acceptance-work) · [文档总索引](../README.md) · [历史资料](../history/README.md)

[分类异常复现分析](Qwen-Diagnostics-Reproduction.md) 使用新增类型化诊断复跑同套场景，区分协议原因、流程判定和执行替身，不改变原判定。


[调用协议对照](Qwen-Protocol-Comparison.md) 区分请求同时提供两类能力、同一响应混用和跨轮分开使用，覆盖 flash/max 与隔离语法对照。

[基础 Skill 常驻时的协议对照](Skill-Protocol-Focused-Comparison.md)比较同 Skill 混合、分 Skill 混合与全 Action；千问 flash/max 小范围实验完成，GPT‑4.1 首次请求返回401，未得到模型输出。不改生产注册。

[内置 Skill 全 Action 迁移](Skill-Action-Migration.md)记录生产注册、Query Channel、原生 Tool 基础能力保留，以及完整 Flash/Max 工作流的实际结果、残留失败和构建边界。早期隔离实验不作为本次生产迁移的验收替代。

- [PlatformKit 容器与设备接入验证](PlatformKit-Containers.md)

- [Direct container input validation](Direct-Container-Input.md): automated/build evidence and outstanding physical/performance checks.

- [Actions container and neutral execution validation](Actions-Container.md): automated/Simulator evidence, retained iteration failures and separate device/model limitations.

- [Execution layer cleanup](Execution-Layers-Cleanup.md): redundant adapters/contracts, physical/Xcode source ownership, context snapshot regression and automated/build evidence.

- [MobileHarness 技术文档核对](Readme-Ownership-Audit.md)记录目录覆盖、链接、Mermaid 渲染及仓库检查。

- [Overall technical design audit](Overall-Design-Audit.md): source-aligned root/authorization/routing contracts, corrected workflow figure placement, 23 rendered Mermaid figures and a tracked execution-policy discrepancy.

- [Native input and internal Signal overview](Signal-Flow-Overview.md): direct sensory/local intake, perception/cognition responsibilities, semantic role communication and execution/feedback, with rendered diagram and evidence boundaries.

- [Action lifecycle responsibilities](Action-Lifecycle-Responsibilities.md): registration, semantic authorization, neutral scheduling/resource validity, business validation and completion ownership, with source-boundary and rendered-diagram evidence.

- [State and conversation context pipeline](State-Context-Pipeline.md): live owner reads, explicit source registration, private Task/Skill projection, per-request message composition and rendered architecture evidence.

- [Passive platform system State](Platform-System-State.md): eight native sources, explicit App injection, bounded observation lifecycle, request context and automated/native evidence limits.

- [Current State before redundant queries](Current-State-First.md): environment-reader scope, BasicSkill direct answers, instruction budgets and model-adherence limits.

- [State summaries and specific queries](State-And-Query-Responsibilities.md): application summary ownership, removed generic environment path, correlated feedback and admission/test/build evidence.

- [NexArm motor teaching and regression](NexArm-Robot-Skill-Regression.md): axis/units teaching, relative motor requests and real-model synthetic-action evidence.

- [Container reflexivity](Container-Reflexivity.md): passive module snapshots, bounded internal tree, Skill-selected disclosure and separate native/device acceptance.

- [Camera preview orientation](Camera-Preview-Orientation.md): portrait-lock crop stability, separate capture/preview axes, geometry regressions and device follow-up.

- [Module lifecycle ownership](Module-Lifecycle-Ownership.md): App Gateway configuration and Actions native lifecycle regression evidence.

- [Actions assembly encapsulation](Actions-Assembly-Encapsulation.md): root construction, registry identity and public-host boundary validation.

- [App responsibility cleanup](App-Responsibility-Cleanup.md): resource/model/session ownership and obsolete App API cleanup.

[BasicSkill 聆听控制](Listening-Actions.md)：启停 Action、许可与会话边界的自动化证据，以及独立真机验收步骤。

- [Window / Camera](Window-Camera.md)：通用窗口、Action 请求链和拍照迁移的自动化证据与独立真机验收边界。

[WebKit 与绘图 Actions](WebKit-Actions.md)记录受限多文件编辑、真实macOS/iOS WebKit、远程浏览/截图和独立模型替身验收；真实模型与物理设备范围单独标注。

[Web Skill 上下文修复](Web-Skill-State-Fix.md)：ui.web漏注册的失败复现、动态打包Skill状态回归及真机修正版交付。

[Web Skill 教学优化](Web-Skill-Teaching.md)：浏览/绘图分轮示例、项目复用、Task与失败边界及协议/预算验证。

[Skill 驱动 State 观察](Skill-State-Observation.md)：统一resolver、完整Business与部分读取失败隔离的验证。

- [Writer 本机双模型多流程回归](Writer-Model-Regression.md)：真实 Qwen/DeepSeek、生产 Writer/Gateway/Storage、macOS WebKit、逐任务诊断及明确平台边界。

- [Writer 快速完成与持续进度](Writer-Continuous-Progress.md)：task_6 真机只读基线、默认流式预览、逐请求进度、自然收尾及独立任务记录页；双模型与原生页面证据分别列示。

- [Writer回合完成与窗口可见性](Writer-Round-Window-Visibility.md)：完成步骤汇报、默认全窗口State、定向Web查询及真实Qwen Skill发现回归；慢请求与设备快照限制单列。
- [Unified Task Actions](Task-Action-Unification.md): foreground/background startTask, executor routing, cancellation acknowledgement and regression evidence.

- [ModelKit Chat concurrency](ModelKit-Chat-Concurrency.md): shared cloud sessions, root-owned local FIFO, cancellation/cleanup, immutable selections and Writer resource-ownership cleanup.

[语音打断后重新聆听](Listening-Interruption-Recovery.md)：取消期间回复终态事实投递与连续重开回归；真机验收另列。

[Storage database and current Writer workspace](Storage-Database-Refactor.md) records the ten-table
refactor, Agent-only model recording, current-file recovery and automated/build/native acceptance limits.

- [Agent 展示调用与反馈所有权](Agent-Presentation-Ownership.md)：角色独立灵动岛、内部调用与模型反馈隔离、回归及构建证据。

- [Complete request logs](Complete-Request-Logs.md): independent full image/request evidence, physical deletion, business preservation, migration and validation boundaries.

- [Database 三层目录与接口职责](Database-Directory-Responsibilities.md)：核心根目录、Shared 中立机制、两侧私有历史接口及独立日志/通信接入的验证。

- [Welcome 云端服务配置](Welcome-Provider-Setup.md)：首次判断、粘贴表单、事务保存与恢复回归；原生验收范围独立记录。

- [Assistant 对话详情](Assistant-Conversation-Detail.md)：同级 State 选择证据、日志清空后的呈现与导出，以及界面验收边界。

- [Writer 任务与请求详情](Writer-Record-Detail.md)。任务信息、五区块详情、来源调用、宿主收尾和日志清除的验证。

- [Assistant / Writer 任务路由](Assistant-Writer-Task-Routing.md)：平级入口、Writer 作品库归属与只查询不创建文件的回归及手机复验。

- [提示词所有权](Prompt-Ownership.md)：Agent 自描述、实际权限目录、私有指令隔离、模板与构建证据。

- [Writer 双模型提示词优化](Writer-Prompt-Optimization.md)：HTML/Markdown/TXT、绘图、作品查改、窗口、追问与边界；保留真实模型结果、评估器修正和产品能力限制。

- [Writer 执行内聚](Writer-Execution-Cohesion.md)：同请求选择作品、无文件完成、渲染后发布恢复与双模型复测。

- [task.start 初始 Skill](Task-Start-Initial-Skills.md)：启动携带单项/多项 Skill 的教学、原子加载与下一轮能力可用性。

- [Writer 记录分页](Writer-Record-Pagination.md)：整页末尾、自动刷新、详情返回保留及验证边界。

- [task_7 委托分组调查](Writer-Task7-Delegation-Diagnosis.md)：手机 SQLite 真实请求与虚假分组、顺序回落和归属回退证据。

- [Writer 委托与 Workspace 解耦验证](Writer-Workspace-Separation.md)：真实 SQLite 回归、构建及独立原生页面验收。

- [Channel override and photo-ignore removal](Remove-Channel-Override-And-Photo-Ignore.md): routing, retained reshoot previews, removed declarations/UI/cues and automated/build evidence.

- [Writer 通信精简](Writer-Communication-Reduction.md) 记录授权关闭、通知拒收与恢复、任务诊断及构建验证。

- [Writer 委派接纳与业务拒绝](Writer-Delegation-Admission.md) 记录正常接纳、模型拒绝、持久理由、授权释放及构建证据。

- [Agent 静态类别](Agent-Categories.md)：类别配置、运行时保留、非法配置拒绝与构建证据。

- [D3 Edge Core AI](D3-Edge-CoreAI.md)：本机 Core AI/PyTorch/Swift 对照、全双工文本三分类、性能与实验性发布证据。
- [Mac 本地 Decision 多分类对照](Decision-Model-Mac-Comparison.md)记录全双工多分类的模型、提示词和时延对照。
- [quiet 退出判定评估](Quiet-Exit-Evaluation.md)记录最新一句话结束 quiet 的 92 条中英用例在 D3、Vela、Laya、Apple 系统模型与云端 qwen3.8-flash 上的准确率、误唤醒与时延，并含简化为“是否要求唤醒”是非问句的提示词变体。
- [新版 quiet 提示词的本地 Decision 对照](Quiet-Exit-Decision-2026-11-25.md)使用新编的 64 条中英用例，分别评估默认邀请、明确授权、直接称名和语义约定。
- [中英 Zipformer KWS 的 Apple ONNX 基线](Zipformer-Apple-ONNX-Baseline-2026-11-25.md)记录 Mac 上两个流式分块制品的命中、误触发和回放时延。
- [中英 Zipformer 的 Core ML 与 ONNX 对照](Zipformer-Apple-CoreML-Comparison-2026-11-25.md)记录同音频上的独立 Core ML 转换、执行提供者分区、准确性和 p95。
- [Hugging Mac Zipformer Core ML 发布版回放](Zipformer-Hugging-Mac-Release.md)记录固定制品、下载校验及冻结音频复测。
- [Zipformer 快速打断配置筛选](Zipformer-Interrupt-Config-2026-11-25.md)记录声学参数、因果门限、两批独立复核及旁路候选。
- [Mac 本地 Decision 打断意图二分类实验](Decision-Binary-Interrupt-Mac-Comparison.md)记录 D3 Edge 与 Vela3 Fast 的三波对照，包括单句、中英提示与 noul／choice、历史上下文。
- [Decision prompt language split](Decision-Model-Mac-Comparison.md#decision-prompt-language-split) compares the current English and Chinese prompts with the pre-split mixed prompt using native D3 and the application adoption policy.
- [小参数生成模型的 Core AI 对照](Decision-Model-Mac-Comparison.md#小参数生成模型的-core-ai-对照)记录 0.6B 至 1.54B 制品在 100 条中英全双工探测上的分类、延迟和提示词复测。

[资源刷新过期误报](Resource-Refresh-Supersession.md)：保存成功快速离页后的迟到刷新、二次错误提示、失败保留和设备交付证据。

- [Agents Support consolidation](Agents-Support-Cleanup.md): source ownership, localization regression coverage, reference checks and required build/test outcomes.

[Agents responsibility boundaries](Agents-Responsibility-Boundaries.md) records role/shared/root ownership regressions and the remaining Metal Toolchain build blocker.

- [模型下载源](Model-Download-Source.md)：系统语言默认、源快照隔离与构建验证。
- [本地 Core AI LLM 的 Decision 输出格式对照](Decision-Local-LLM-Output-Formats.md)记录五个制品在候选打分、完整单词、完整数字和 Tool Call 的结果及 500 ms 预算。
- [本地 Core AI Decision 中英文数字提示词对照](Decision-Local-LLM-Bilingual-Digits.md)记录 5 个通用 LLM 的中英文提示运行，以及 D3 原生 Choice、整段原文和旧提示的同批对照，另记录删去动作定义的复测。每组 100 条，逐条预算 500 ms。

[Apple system LLM](Apple-System-LLM.md) records standalone provider compilation, contract tests, whole-workspace check failures and native-model acceptance limits.

- [D3 iOS AOT validation](D3-iOS-AOT.md): compiler artifacts, publication, architecture selection and device-acceptance limits.

[Decision 首页预加载](Decision-Startup-Preparation.md)：选中本地模型的启动准备、取消/重检、构建与验收边界。

- [DeepFilterNet3 capability](DeepFilterNet3-Capability.md): independent enhancement DSP and Core ML validation.

[DeepFilterNet3 listening integration](DeepFilterNet3-Listening.md) records optional startup loading, settings/workflow tests, real-model host timing and full-suite/device acceptance limitations.

[D3 Edge 继续聆听四分类实验](Decision-Model-Mac-Comparison.md#d3-edge-继续聆听四分类实验2026-11-16)：最新生产提示、194条双语扩展场景、真实App采纳与独立原生读出，区分低召回、250ms超时及512-token容量。

[D3 Edge 提示词结构优化](Decision-Model-Mac-Comparison.md#d3-edge-提示词结构优化实验2026-11-16仅实验环境)：官方/公开集成调研、11组对照与48条预冻结留出；仅实验，保留误继续聆听风险及生产未变的哈希证据。

- [ModelKit 制品所有权与 D3 Lite 移除](ModelKit-Artifact-Ownership.md)：独立存储、下载、目录与回归验证。

- [Tests 目录整理验证](Tests-Organization.md)

- [实验与评估目录迁移验证](Experiments-Organization.md)

- [任务评估集与共享制品验证](Evaluation-Datasets.md)

- [Research / Engineering 职责修正验证](Research-Engineering-Responsibilities.md)

- [仓库脚本整理验证](Scripts-Organization.md)：离线工具回归、五个 iOS 构建与全量测试限制。

- [模块与链路测试覆盖审查](Module-Test-Coverage.md)：八模块基本功能、跨模块集成证据、生产装配缺口与失效用例。

- [模块测试修复验证](Module-Test-Repairs.md)：归属、夹具、时序契约和真实 App 装配验收。

- [实验数据职责整理](Experiment-Data-Ownership.md)：任务输入、原始结果与文档分离及验证。

- [experiments 命名验证](Experiment-Naming.md)：统一文件名与引用校验。

- [纯 Python 实验验证](Python-Experiments.md)：Research 与 Swift 工程测试解耦及运行证据。

- [Tests / experiments 独立验证](Independent-Research-Tests.md)：仅共享模型制品，源码、数据和验证入口独立。

- [State 泛化后的控制提示词评估](State-Controls-Prompt-Evaluation.md)：state/skill/send 控制库的 qwen3.8-flash 实验结果与对照。
