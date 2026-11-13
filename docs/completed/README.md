# 已完成需求归档

- [MobileHarness 技术文档核对](Readme-Ownership-Audit.md)（2026-11-14）。总设计、九个一级模块和子目录的职责、数据流与实现说明同步。

- [Agent 静态类别](Agent-Categories.md)（2026-11-10）：perception/cognition 资源声明、运行时身份保留与严格配置校验。

- [Writer 按 ID 直接打开和进入](Writer-Direct-Workspace-Access.md)（2026-11-10）。已知工作区 ID 可直接使用，搜索用于发现作品。

- [Writer 精选事件播报](Writer-Selective-Assistant-Feedback.md)（2026-11-10）。接纳、里程碑、追问和终态进入 Assistant 语音与后续对话上下文。

- [相机照片查看、批量保存和直接关闭](Camera-Photo-Review-Actions.md)（2026-11-09）。五张缓存照片可供同轮查看，支持批量保存和无照片确认框的关闭。

- [Writer Markdown 与 Mermaid 渲染](Writer-Markdown-Mermaid.md)（2026-11-09）。离线文档解析、Mermaid 图表和窗口预览验证。

- [相机设置、预览及 Writer 回馈](Camera-and-Writer-Feedback.md)（2026-11-09）。相机局部设置和预览完成语义，Writer 灵动岛回馈及普通进度收敛。

- [Writer 持续后台执行](Writer-Continued-Background-Execution.md)（2026-11-09）。接入 iOS 持续后台任务，验证工作流继续、过期清理和 App 配置。

- [相机设置与卸载预览的成功回执](Camera-Success-Observations.md)（2026-11-09）。两项相机 Action 改为 Void，验证结构化完成与异常传播。

- [Action 成功回执与业务观察](Action-Success-Observations.md)（2026-11-09）。24 个纯操作 Action 改为 Void，验证成功不续轮和异常反馈。

- [Writer 委派接纳与业务拒绝](Writer-Delegation-Admission.md)（2026-11-09）。移除后台契约白名单，增加模型拒绝终态及验证。

- [精简 Writer 通信](Writer-Communication-Reduction.md)（2026-11-09）。四项入站和两项出站，运行时收尾独立于持久业务通知。

- [独立 Agent 业务、纯通信与 HTTP 日志](Message-Agent-Business-Separation.md)（2026-11-07）：Assistant/Writer 独立十表、按表目录、业务与历史 UI 改造、旧代码清理和真机清洁安装。
- [Database 表归属与日志清空](Database-Table-Ownership.md)（2026-11-07）：表目录与仓库归属、清空日志入口及后续独立表结构。
- [完整请求日志与独立清空](Complete-Request-Logs.md)（2026-11-07）：原始 HTTP/图片/generation meta 可删除日志，业务记录独立保留；以独立 Agent 后续设计为当前边界。

- [可读预览编号与合并图片输入](Readable-Preview-Context.md)（2026-11-06）：preview_N、独立持久 ID、原始用户输入内的 State 图片和 system 元信息关联。
- [预览图片历史读取修复](Preview-History-Images.md)（2026-11-06）：缓存与已保存原图读取、引用校验、过期提示及真机安装。
- [预览缓存与多模态 State](Preview-Image-State.md)（2026-11-06）：三层图片存储、跨轮按需加载、Camera 自有选择／处置和请求日志脱敏。
- [Writer 执行与续写生命周期](Writer-Execution-Lifetime.md)（2026-11-06）：工具接纳与直接续写的边界、撤销、互斥、加入清理、根关闭及自动验证。

本目录集中保存原定范围已经全部完成的需求与实施计划。归档的是一次明确的交付范围，后续独立 bug 修复或 feature 扩展不影响原需求的完成状态。当前实现以源码 README 为准，归档文档保留当时的目标、决策和实施记录。

## 归档规则

1. 核对原范围的功能、接口、迁移、清理和明确约定的必要验收；仍有原定交付缺项时不能归档，也不能将其改称后续扩展。
2. 部分完成的需求整份保留在 requirements，更新子项状态；只有原范围全部完成后才整份迁入本目录，不按已完成章节提前归档。
3. 归档记录日期、完成范围及验证来源，更新所有引用，不保留两份相同的活动需求。
4. 后续修复与扩展使用独立记录；归档中的历史失败、构建限制和另行跟踪的模型/设备验收保持真实，不因归档改写为通过。若某项验收本身属于原需求完成条件，则完成前不能归档。
5. ADR、验证报告、原始设计源和通用变更历史按各自目录职责保存；文件中出现“完成”不代表它就是需求文档。

## 本次归档

整理日期：2026-10-15。以下归档范围均已有实施完成记录；归档日期不代替实际实现或验证日期。

| 文档 | 已完成的原范围 |
| --- | --- |
| [Action 文档与流程 Skills](Action-Documentation-Skills-Plan.md) | Action 声明替代重复元数据，模块自动投影，以及流程教学迁入 Skills。 |
| [Tasks 与独立 Skills 迁移](Agents-Skills-Task-Modes-Plan.md) | 通用 Task、独立 Skill 机制及其 Assistant、历史和 UI 迁移。生产后台业务与物理体验不属于该机制迁移的新增交付。 |
| [ModelKit Support 重组](ModelKit-Support-Plan.md) | 源码职责与编译边界重组、重复模块清理及调用迁移。 |
| [ModelKit 解耦审计](ModelKit-Decoupling-Audit.md) | 中性 Core 契约、SDK 依赖隔离、完整源码审计和当前设计文档对齐。 |
| [SQLite 业务记录迁移](Prefix-Numeric-ID-Plan.md) | 业务 ID、逐消息持久化、索引查询和媒体文件命名/提交迁移。 |
| [Storage 仓库与后端分离](Storage-Repository-Plan.md) | 独立领域契约、File/Memory/SQLite 后端及调用迁移。其后新增的自动历史分页属于独立页面扩展，不改变原接口分离的完成状态。 |

各文档中的测试失败、模拟器依赖限制和独立真机验收状态原样保留，具体以其验证记录为准。

## 仍未整体完成

[四项核心架构改进](../requirements/technical/Core-Architecture-Improvement-Plan.md) 只有存储接口子项完成；状态转换、全局错误处理和 App 解耦仍待实施，整份继续留在 requirements。相册与记忆、Resource 状态接入、摄影构图与运镜也继续留在各自待办分类。

[未完成需求](../requirements/README.md) · [文档总索引](../README.md) · [验证记录](../validation/Validation-History.md)

## 业务组织整理（2026-10-23）

- [Actions 业务组织与端点解耦](Actions-Organization.md)：业务目录归位、共享 Support、显式端点及生命周期所有权。
- [Agents 角色归属与共享机制](Agents-Organization.md)：根级装配、角色私有协议与通用机制分离，以及职责一致的文件组织。

原定整理范围与完整自动检查已完成；模拟器构建使用隔离项目元数据读取同一工作区源码。原工程文件协调阻塞、修正过程及未进行的真实模型／设备验收见[验证记录](../validation/Agents-Actions-Organization.md)。

## Actions execution ownership (2026-10-25)

- [Actions container and one-way execution](Actions-Container.md): one App-owned Actions root, composable business library, neutral Gateway preparation/scheduling and Agent-owned authorization. Required repository checks and all four Simulator builds passed; retained failure iterations and native/model/device evidence limits are in [validation](../validation/Actions-Container.md).

## Execution layer cleanup (2026-10-25)

- [Execution layer source ownership audit](Execution-Layers-Cleanup.md): consolidate six net Swift files, remove unused adapters/helpers, reconcile physical and Xcode ownership, and correct stale cognitive authorization diagrams. Full repository checks and all four Simulator schemes passed; [validation evidence](../validation/Execution-Layers-Cleanup.md) distinguishes build/test results from model/device acceptance.

- [Platform system facts](Platform-System-State.md): eight passive native sources and BasicSkill context, implemented with required checks/builds; independent native acceptance limits remain explicit.

- [Current State before redundant queries](Current-State-First.md): BasicSkill direct answers, precise environment-query scope and unchanged instruction budgets; [validation](../validation/Current-State-First.md) separates automated/build checks from real LLM adherence.

## State summaries and detail queries (2026-10-26)

- [State and query responsibilities](State-And-Query-Responsibilities.md): agents.application summary, removal of the generic environment Action/reverse binding, preserved specific queries and correlated feedback, with [automated/build evidence](../validation/State-And-Query-Responsibilities.md).

[NexArm 位置跟踪恢复](NexArm-Position-Tracking-Restore.md)：恢复有限角度目标，删除持续速度及取消恢复写入，收紧USB/BLE原始寄存器写校验。代码和自动化验证完成，实机边界见归档记录。

2026-10-27：[NexArm 位置跟随平滑](NexArm-Smooth-Position-Tracking.md) 已完成位置目标 20 Hz 更新、时间滤波、最新目标派发和 PlatformKit 设备约束归属，自动检查与 iOS 构建通过；未安装或验证机械臂实物。

2026-10-27：[NexArm 通用设备反馈与连接错误归属](NexArm-Device-Feedback-Ownership.md) 完成SDK容差、位置观察、行程估算及原生恢复预算/分类迁移；全量自动检查和四项iOS构建通过，未安装或实物测试。

- [NexArm motor teaching and regression](NexArm-Robot-Skill-Teaching.md): relative motor requests, unit/axis teaching and three-model experiments with retained failure evidence.

- [Explicit execution composition](Explicit-Execution-Composition.md): App-sequenced preparation and module-owned configuration; automated checks and simulator build passed.

- [Module lifecycle ownership](Module-Lifecycle-Ownership.md): Actions owns native scene cleanup; App directly configures Gateway.

- [Actions assembly encapsulation](Actions-Assembly-Encapsulation.md): private business construction and public host capabilities.

- [App responsibility cleanup](App-Responsibility-Cleanup.md): root/entry boundaries, module-owned mechanisms and retired projections.

## BasicSkill 聆听控制

[聆听启停 Actions](Listening-Actions-Plan.md)：无参数 startListening/stopListening、统一许可 owner、原生清理加入及 BasicSkill 教学。代码、文档和自动检查已完成；独立真实模型/真机验收见 [验证记录](../validation/Listening-Actions.md)。

## WebKit 与网页 Actions（2026-11-03）

[WebKit 浏览与本地绘图](WebKit-Actions-Plan.md)：8项Action、独立多轮模型编辑、多文件局部修改、隔离版本工作区、截图观察和两个Skill。完整检查、四项iOS构建、真实macOS WebKit与iOS模拟器验证通过；真实模型和物理设备验收边界见[验证记录](../validation/WebKit-Actions.md)。

[Web Skill 上下文接入修复](Web-Skill-State-Fix.md)（2026-11-03）：补齐ui.web显式注册、被动业务事实和全部打包Skill加载/采集/释放回归；自动检查、iOS构建和真机修正版交付见[验证记录](../validation/Web-Skill-State-Fix.md)。

[Web Skill 教学优化](Web-Skill-Teaching.md)（2026-11-03）：浏览/绘图revision2、分轮示例和项目复用教学；示例解析、提示预算、完整检查与四项iOS构建通过。

[Skill 驱动 State 观察](Skill-State-Observation.md)（2026-11-03）：Skill独占范围选择、统一App读取、完整Business及单项unknown诊断；验证见[专项记录](../validation/Skill-State-Observation.md)。

## Agent 展示调用与反馈所有权（2026-11-06）

[角色内聚展示与调用来源隔离](Agent-Presentation-Ownership-Plan.md)：语音/相机/连接角色自有灵动岛、共享机制边界及仅模型调用可反馈续轮；完整检查与四项 iOS 构建通过，见 [验证记录](../validation/Agent-Presentation-Ownership.md)。

- [App 内灵动岛全局显示](Global-In-App-Island.md)：保持顶部位置，所有页面共享实时状态与展开偏好；验证及设备限制见专项记录。

- [Database 目录与私有接口解耦](Database-Directory-Responsibilities.md)：Assistant/Writer 分别拥有历史与任务接口，共享日志和通信；检查与 iOS 构建见[验证记录](../validation/Database-Directory-Responsibilities.md)。

- [首次 Welcome 云端服务配置](Welcome-Provider-Setup.md)：默认 OpenAI、URL/密钥粘贴、事务保存与独立模型选择；检查结果和验收边界见[验证记录](../validation/Welcome-Provider-Setup.md)。

- [Assistant 对话详情精简](Assistant-Conversation-Detail.md)：独立 Task/Skill/State 展示、删除冗余执行预览与日志清空呈现；验证见[记录](../validation/Assistant-Conversation-Detail.md)。

- [Writer 任务与请求详情](Writer-Record-Detail.md)（2026-11-08）：任务信息、业务区块、工具目录及按文件路径折叠的 Content；[验证记录](../validation/Writer-Record-Detail.md)。

- [Writer 请求详情布局与接口](Writer-Request-Detail-Layout.md)（2026-11-08）。独立详情接口、五区块布局、工具来源和宿主收尾。

- [Writer 请求与作品选择内聚](Writer-Execution-Cohesion.md)（2026-11-08）：同一通信请求内自选作品、历史原子接续、无文件完成与渲染后发布恢复；双模型和构建证据独立归档。

- [前台任务启动加载 Skill](Task-Start-Initial-Skills.md)（2026-11-08）：单次 task.start 携带必要 Skill 的教学、单项/多项示例与下一轮能力可用性回归。

- [Writer 记录分页](Writer-Record-Pagination.md)：准确末页与导航返回保留；完整自动检查和 iOS 构建通过，原生交互另行复验。

- [删除 Channel 覆盖与照片忽略](Remove-Channel-Override-And-Photo-Ignore.md)（2026-11-09）：固定注册 Channel，删除照片忽略 Action/UI/缓存状态/音效/教学；完整检查和四项 iOS 构建通过。

- [Writer 批量打开作品与网页多窗口](Writer-and-Web-Multiwindow.md)（2026-11-09）。批量打开、多窗口及定向换站的调查和检查见[验证记录](../validation/Writer-and-Web-Multiwindow.md)。

- [Writer 显式结束委托与通用作品打开](Writer-Explicit-Finish-and-Open.md)（2026-11-09）。统一 finish，按模型选定的作品逐件打开。

- [Writer 工具注册拆分](Writer-Tool-Separation.md)（2026-11-09）。各操作独立注册，Writer 保有委托与编辑会话编排。

- [Writer Skill 统一注册与工作区切换](Writer-Skill-Registration-and-Switching.md)（2026-11-09）。两阶段由 Skill 声明工具与教学，支持保留旧草稿后切换。

- [Writer 工具与工作区身份](Writer-Workspace-Tools-and-Identity.md)（2026-11-10）。统一作品 ID、精简 Skill 教学并验证直接新建和续作。

- [Writer 重复创建与缺入口恢复](Writer-Create-Loop.md)（2026-11-09）。同一委托复用创建分配，初始化时创建入口文件，旧草稿缺入口引导到 edit。

- [D3 Edge Core AI conversion](D3-Edge-CoreAI-Conversion.md)：文本模型转换、对照验证与 Hugging Face 发布完成；业务误判、数值漂移和平台边界见专项验证。
