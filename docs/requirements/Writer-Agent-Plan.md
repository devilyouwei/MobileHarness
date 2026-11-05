# WriterAgent 流式创作计划

2026-11-03。用户已批准本计划实施及新增 Agents/Writer、Actions/Artifacts、Resources/Agents/Writer、Resources/Skills/Writing 目录。基线 ada643ae，分支 codex/writer-agent。

## 目标与责任

Writer 独立于 Assistant 的模型选择、上下文、工作流和协议；原生工具控制与原始内容生成请求分离，不使用 XML/Channel。首期 HTML/CSS/JS、Markdown、TXT；DOCX 后续扩展。Assistant 短委托，原始请求由授权运行时绑定，源码不进入 Assistant 历史。远程浏览保留。

Agents/Writer 拥有控制循环、内容流、任务和上下文；Actions/Artifacts 拥有确定性工作区、版本、编辑事务、草稿；Actions/Web 保留浏览/呈现；Gateway 直接调用身份/取消/结果；UI 多页面与增量预览；Storage/ModelKit 保持基础模块独立。App 通过中立契约组合，不新增第一层模块或编译目标。

## 实施顺序与接口

1. 作品服务：迁移 WebWorkspace 到 Artifacts，采用当前项目 ID/版本/路径结构，不导入旧索引；加入格式、MD/TXT、草稿、版本/范围绑定的局部编辑，开始/追加/完成/取消流会话。
2. Writer：独立容器/执行会话/模型配置；原生工具 list/read/search/edit/render/finish；编辑工具建立目标，子请求仅流式生成内容。工具与结果配对，预算内压缩历史。读取范围引用避免大段源码工具参数。
3. 呈现：多项目/窗口隔离。Writer 显式 render 或按次 edit(preview=stream) 开启 TXT/Markdown/HTML/CSS 脚本禁用预览；显式 render 运行 JS，200ms 合并检查点并在完成时刷新，源码背压不丢弃。
4. 生产后台任务 writer.author：request/input/progress/result/cancel，短委托与授权原始输入；返回接纳，不阻塞 Assistant。检查点合并追加修改。完成/失败/需要输入通知原会话，去重且不打断正在输出的回复。
5. 模型设置：Provider 稳定 ID 与 Writer 独立选择，复用凭据；任务固定配置，不支持原生工具显式拒绝，不回退 XML。
6. 删除旧 Web.develop/WebEditor 及模型注入/技能入口；Writing 取代绘图教学，浏览保留。更新架构/模块 README、资源目录/Package/工程与边界检查。

## 生命周期、限额和失败

两项活动创作，不同项目并行，同项目单写；八条待处理修订，超限拒绝。每任务24控制请求+24内容请求、10分钟。现有8项目/16版本/32文件/64KiB文件/256KiB项目上限保持，每项目一份最新草稿。窗口关闭/最小化不取消创作；显式取消加入清理。后台检查点保存并取消推理/预览，前台恢复有效任务；进程重启只恢复中断状态、由用户继续。取消/失败不覆盖成功版本。草稿流代际/版本围栏拒绝迟到写入。内容来自不可信观察，不产生授权。

## 验收与状态

代码链路已实现，最终自动化复核与独立验收见 [验证记录](../validation/Writer-Agent.md)。真实模型/真机验收仍未完成，暂不归档。必须验证随机/逐字符分片、Unicode/标签/引号跨分片、截断/背压、局部修改与版本冲突、当前格式重开、单任务/取消/消息隔离、窗口生命周期、模型选择及不支持能力。运行 scripts/check.sh、scripts/build-ios.sh；真实模型、模拟器、真机独立记录，复测 Transformer 图/动画/连续修改/远程浏览。未验证项不得标记通过。

技术文档同步范围：Agents/Writer 与 Agents/Support/Communication、Assistant、Agent 根；Actions/Artifacts、Web 与 Actions 根；UI/Web、Window、Root 与 UI 根；Provider、ModelKit 对应能力；Resources/Agents、Skills；App Composition、总体 MobileHarness README；Tests 及验证记录。过渡期间保留旧链路只为迁移验证，最终移除，不保留双开发实现。

实施细化：需要输入时 Writer 释放模型和工作区租约，保留任务与草稿，通过 waitingUser/interactionID 通知原会话；输入后重新建立私有观察，从草稿继续。前后台恢复共享同一个请求预算，避免恢复重置上限。工具参数错误作为有界观察反馈，取消、内容截断和持久化失败仍终止。显式打开作品可重新打开已关闭窗口；流更新不会重新打开。删除作品同时清理预览和页面绑定。新增 remove 文件操作要求有效读取引用，不允许删除入口文件。

实现与验证补充：Writer 模型租约保留同配置的重开端口，任务暂停/追问后的恢复不会读取新设置。工作区仅使用 Storage 分配的 ArtifactWorkspaces，不导入旧 WebWorkspaces。最小化作品保留最新预览，恢复窗口后呈现；原会话通知有界32项，切换会话时保留至原会话空闲。

窗口并发细化：同项目呈现串行、最多两个可取消等待者；关闭先标记并移除页面，中断导航只报告视觉验证不可用，随后加入呈现再清理临时文件，不因此取消创作。打开/删除也持有项目锁，防止与新编辑交错。

## 编辑工具、原生文件操作与实时呈现细化

用户补充约束：参考 DeepSeek Harness 的编辑工具源码、工具提示词和工作流，以及 Claude Code 官方公开工具与预览文档；不复制桌面 Shell 执行环境，不改框架级设计。创作策略、工具说明、格式 Instruction、相关文件上下文、生成与修正循环统一由 Agents/Writer 拥有。Actions/Artifacts 可扩充确定性业务执行，Storage/UI/ModelKit 只提供既有职责范围内的基础能力。不改变 Agent 委托、Gateway 协议、ChannelScheduler 或基础模块依赖方向，不引入新的通用 Agent 框架。

### 工具与上下文

- 在现有 Writer 工作流内细化工具 schema、使用提示和错误修复指引：文件发现 → 读取关联内容 → 定位修改 → 流式生成 → 查看差异与预览诊断 → 修正 → 发布。无需固定执行全部步骤，已知目标可直接读取；Writer 决定何时 render；普通编辑不触发预览，edit(preview=stream) 显式开启该次编辑的流式预览。
- 文件工具覆盖项目内目录/文件的增删改查，以及移动、重命名；使用项目相对路径，支持嵌套目录。由 Actions/Artifacts 管理作品目录语义、入口引用和版本；原生调用 StorageFiles 受控 workspaces 命名空间，不执行 Shell、命令行搜索或进程。不得把临时预览目录或宿主绝对路径变成模型可写根。通用文件接口确有缺项时只补基础文件操作，不把作品规则下沉 Storage。
- 读取返回行号、范围、文件版本和内容引用；查询支持路径过滤、匹配上下文、有界分页和明确截断信息。精确定位失败、目标不唯一、文件版本冲突必须返回可供 Writer 重新读取/定位的错误。文件版本隔离，修改一个文件不使其他未变化文件的引用失效。
- 工具参数携带短编辑意图、目标和关联内容引用；宿主为内容请求装配实际相关文件片段，保留路径/版本并控制上下文预算。不可只传文件名，也不可要求控制模型把读过的源码再复制到参数。源码/替换片段仍采用原始内容流，不退回 XML 或大段 JSON 源码参数。
- 增加修改差异、成组修改、移动/重命名和版本恢复。成组修改先在草稿验证，发布沿用既有不可变版本/CAS；不宣称底层多文件操作天然原子。失败、取消及部分草稿保留的语义须明确。
- Writer 内置通用修改规则与 HTML/CSS/JS、Markdown、TXT 等格式 Instruction，按任务和目标文件选择注入；SVG/JSON 使用相应辅助格式约束。不引入 Writer 动态 Skill 加载。Assistant 的 Writing Skill 继续只教委托和结果使用。

### Writer 控制的流式呈现

- 内容流追加，以及新增、删除、局部修改、移动、重命名、恢复版本，都使既有验证失效；仅 Writer 显式 render 或当前 edit 开启流式预览时更新窗口；渲染始终使用该作品同一 revision 的完整文件集合，避免 HTML/CSS/JS 混用不同快照。没有修改的查询不触发渲染。
- 源码增量按顺序完整接收，持久化/生成背压不得静默丢数据。视觉帧允许按短时间窗合并为最新快照，队列有界；必须有尾沿刷新，最后一个增量即使没有后续 token 也能呈现。目标延续现有约 200ms 合并间隔，正常流结束强制刷新最终内容，不承诺每 token 重载一次 WebKit。
- HTML/CSS/Markdown 等在生成过程中产生可预览检查点；不完整标签、字符串、样式和脚本不得被当作完整执行单元。完整源码仍保留，界面明确区分正在生成的预览与完整可运行检查点。流式预览禁用脚本；Writer 调用 render 后执行完整草稿，避免中间文件组合的脚本副作用。检查点不等于语法正确，执行错误仍反馈 Writer。
- 普通变化只修改草稿；render 工具执行最新草稿并请求诊断/截图。返回渲染 revision、诊断、截图是否可用及验证状态；finish 不再仅靠曾调用 render 的布尔标记代表验证。保存成功、可预览、运行验证通过分别记录。
- 窗口最小化/关闭沿用既有生命周期约定：保留最新草稿，不强行重开或声称不可见窗口已视觉验证；恢复可见时呈现最新 revision。不同作品独立合并与渲染，一个窗口的连续更新不排在另一个作品的生成队列之后。应用进入后台仍遵循现有暂停机制，不保证 iOS 后台持续运行。

### 文件范围与验收

主要涉及 Agents/Writer/WriterWorkflow.swift 与域内工具定义/Instruction、Actions/Artifacts/ArtifactEditing.swift、ArtifactService.swift、ArtifactWorkspace.swift、ArtifactPresentation.swift、ArtifactContentParser.swift；UI/Components/Web 只在基础页面更新/诊断接口确有需要时扩展。Storage/Files 只在现有原生接口无法覆盖操作时补通用能力。实施后同步各拥有目录 README；不把本节待实现行为写成技术 README 的现有契约。

验收重点：跨文件选择器/脚本引用一致，搜索超限可继续，Unicode 行范围与精确定位，单文件版本冲突隔离，目录操作沙盒与入口一致性；流末尾强制刷新、随机分片、不完整 HTML/CSS/JS、CSS/JS 单独变化、删除/重命名刷新、多文件一致快照；双窗口并行、关闭/恢复、取消与迟到帧隔离。自动化/模拟器渲染结果与真实模型、真机体验分别记录。

参考：
- [DeepSeek 文件能力分层](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/fs/README.md)、[读取工具](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/fs/tool-fs/src/read.ts)、[编辑工具](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/fs/tool-fs/src/edit.ts)、[多文件补丁](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/fs/tool-fs/src/apply-patch.ts)。
- [Claude Code 官方工具说明](https://code.claude.com/docs/en/tools-reference)、[Desktop 预览与验证](https://code.claude.com/docs/en/desktop)。官方公开仓库不包含完整核心实现，文档行为不作为源码审计结论。

实施收敛：沿用相对文件路径形成隐式目录（随首个文件创建、最后文件删除而消失），不保存空目录。目录移动/删除使用子树操作并要求所有受影响文件已读取；入口不可删除，移动入口同步更新 entry。草稿提供最多八个显式 savepoint/restore 检查点用于多文件修改撤销；公开历史版本恢复另经已有版本文件读取，不更改 Storage schema。格式 Instruction 在 Writer 内容请求中按目标扩展名选择。

本轮实现范围：原生路径/子树操作、行读取、字面搜索分页、按文件引用与关联上下文、显式与按次流式渲染、格式 Instruction、savepoint/diff/restore、保留版本读取恢复已落入现有 Writer/Artifacts 目录。没有新增目录或修改框架协议。检查和设备证据见验证记录；正则查询、DOM交互测试、空目录持久化不属于本次实现。

目录移动复核补充：UI/Components/Web/WebPageContainer 的具体本地加载方法增加可选 readAccessRoot（不改变 WebPagePresenting 协议）；入口仍需通过 WebPagePolicy 的根内/符号链接校验。Artifacts 从当前预览版本的受控 URL 推导版本根，允许嵌套入口引用同作品兄弟目录。默认调用继续以入口父目录为根。新增模拟器嵌套入口/CSS/JS 检查，并保持预览禁用脚本。

## Writer 历史、作品浏览与导出（已实现，验收边界见验证记录）

需求：设置 → Agent 记录加入 Writer；持久保存控制请求、内容请求、回复、工具调用、用量与失败，支持查看作品目录/源码并导出原文件，Markdown/HTML/TXT 支持 PDF 导出。既有记录不伪造回填。

职责与文件：Agents/Writer 增加域内请求记录器，复用 StorageChat.ConversationHistoryStore/ConversationRecordStore，并以 agent=writer 绑定 App 已注入的同一 SQLite Chat/Task repositories；不把写作内容混入 Assistant，也不新建 SQLite 旁路。每个真实模型请求保留独立历史输入与请求证据，标注任务、项目和控制/内容阶段，失败/取消收尾入库。原始工具结果保留在后续请求上下文；截图经 CapturedPhotoStore 保存并记录受身份约束的 imageReferences，避免将多MB二进制重复塞进文本列。正常文本与工具事件在内存有界累积，完成边界 SQLite 提交，进程中断沿用现有 interrupted 恢复语义。

UI/Settings 增加 Writer 记录与作品展示接口/页面，复用 ConversationHistoryView 及其 JSON 分享。App/Composition 仅组合 Writer 历史 store、Actions 历史查询适配与 UI 状态；Actions/Artifacts 增加作品列举、单文件读取、原文件导出和 PDF 导出服务。记录浏览与作品导出独立于创作任务生命周期，单次页面操作可取消，不影响 Writer。原文件导出使用系统分享，项目批量导出使用保持相对目录的归档。导出基于固定作品/草稿快照，明确区分草稿和已发布版本。

UI/Components/Web 仅补通用本地文档 PDF 能力：受控读取根、禁用外部资源、独立页面，不占用正在创作的窗口；Markdown/TXT 使用现有转换器，HTML 使用 WebKit。PDF 按 A4 页面生成，验证非空/容量/页数；有界准入、超时和取消，临时文件通过 StorageFiles 导出命名空间管理并清理。复杂布局、动画导出为静态页面，不宣称完全支持所有浏览器打印样式。

不新增目录/模块，不修改 Gateway/Channel 协议。实现后更新 Writer、Artifacts、History、UI Settings/Web、App Composition 及总体 README；添加 SQLite 重开/角色隔离、请求失败/取消、文件快照/目录保留、PDF 与设置页入口回归，运行完整检查、iOS 构建与原生导出验证。历史请求 JSON 不含 provider key。

历史关联细化：Writer 的委托 Task ID 保存在请求 decisionMetadata 与标题中，不写入 Assistant 所拥有 Task 的 message-source 外键集合，避免 Writer 的私有源码被 Assistant 的任务压缩读取。每个请求的 temperature/maximumOutputTokens 从实际请求保存；截图保存真实 imageReferences，读取遵守媒体所有权与回收策略。Writer 历史模型名称当前标记角色 Writer，不能冒称具体 provider/model 已记录。

框架边界复核：历史查询复用 Actions 的分页投影；新建/删除/标题修改由 UI 意图 → WriterContainer/WriterAgent → 既有 Gateway direct → Artifacts.Workspace 历史命令 → HistoryMutationService 执行，不能在历史 UI workflow 直接修改仓库。通过现有业务装配端口绑定 writer 专属 store，不扩展中立流协议；历史命令不向模型暴露，且 Writer 活跃任务期间拒绝归档切换。

截图上下文补充：为与 Assistant 的历史能力一致，Writer 实际使用的截图通过同一 CapturedPhotoStore 保存（SQLite 媒体元数据＋StorageFiles 字节），历史 requestJSON 保存 imageReferences。按 Writer/输入身份校验读取，沿用现有媒体容量/回收策略；不将 base64 塞入聊天文本。替代前述仅保留 imageMetadata 的阶段性设计。

历史管理回归采用生产注册方式：Writer 是跨委托会话的长期角色，AgentManager 注册不绑定单个委托 session；历史 UI 使用独立 writer-history 会话，仍受角色实例与 Gateway 身份校验。测试不额外缩窄成单会话角色。

## 单任务委托与主动消息改造（代码已实现，人工验收待完成，2026-11-03）

按用户确认的方案：默认原生工具 delegateTask(target,goal,projectID?,title?,entry?) 直接建立独立 Writer 后台任务；sendMessage(taskID,type,text?,interactionID?) 修改/取消，移除旧 Writing 工具入口。goal 单行 1024 UTF-8 字节，与实际当前输入共同送入 Writer，不创建 Assistant 前台 Task。Writer 单任务（包括等待、暂停、清理），忙碌明确拒绝，新目标由 Assistant 先征求结束当前任务的确认。

沿用 AgentTaskSignal 与 AgentTaskContent，在现有 Agents/Support/Communication 目录扩充可选版本化 Writer 事件元数据，包含 eventID、序号、类型及作品/窗口身份。started/progress 更新状态；userInput/completed/failed/cancelled 进入 Assistant 同一有界 FIFO，触发模型面向用户回复，不再固定文本播报。移除 writerNotices 旁路。保持可信来源和原会话关联、事件去重、显式容量失败，Writer 有界重送通知不重跑创作。语音只打断当前播报，最终识别与 Agent 消息按接纳顺序处理。

Writer 先经 Gateway direct 建立工作区和窗口再请求模型；Actions/Artifacts 负责准备占位和既有作品展示，原 render/流式预览机制保留。Actions/UI/Runtime 依据任务日志投影独立 Writer 紫色灵动岛详情，与语音状态并存，保留终态，阶段变化展开，普通进度尊重手动收起。UI 仅增加通用紫色 tone。所有长任务保持根拥有，现有 SQLite 保存输入/状态/历史，不新增目录或框架调度机制。

涉及 Task Actions/绑定、Assistant 默认 Skill/提示词、ChatWorker 接纳及上下文、Writer 状态/消息、Artifacts 准备、Island 投影及通用颜色。实现后同步各拥有目录 README 和整体流程文档。回归覆盖默认直接委托、单任务竞争、追问/定向回应、FIFO/去重/满队列/终态、窗口早于模型、岛并存与历史；执行 check.sh、build-ios.sh，独立标注原生模拟器/真机/真实模型可验收范围。


实施协议细化：Gateway 对拒收 result 会执行终态清理，不能在该边界重试。因此 Writer 先用既有 progress 传输版本化 completed/failed/cancelled 业务事件，待 Assistant 队列成功接纳后发送携带同一 eventID 的 result 确认；确认只关闭任务，不再次触发模型。每个 Writer 仅有一个在途消息，500ms 重送间隔，根停止退出并报告失败。此方案不修改 Gateway。Assistant 复用 AgentAdmissionGate 串行化文本/最终语音/Writer 事件的短接纳事务，阻止异步 SQLite 写入改变 FIFO 顺序。语音 interrupt 不清除排队输入或取消 Writer，显式 close/根关闭仍清理自身作用域。

窗口生命周期细化：新增内部 resume 工作区命令，供同一 Writer 任务的追问/暂停恢复使用。start 是新委托，显式清除先前窗口关闭标记并恢复最小化窗口；resume 不改变用户关闭/最小化偏好。二者都先绑定草稿，且不暴露为模型选择的编辑命令。避免为了“委托先显示窗口”而在每次任务恢复时重开被用户关闭的窗口。

并发校验补充：Assistant 创建模型历史记录的 read-token/begin 短事务与输入接纳共用 admission gate，避免 SQLite 接纳新事件使模型请求的历史令牌失效；锁仅覆盖历史提交，不覆盖模型生成或工具执行。

## Assistant 协议与调度修正（2026-11-03）

按用户纠正，Assistant 对模型只开放 XML Function Token Action；delegateTask/sendMessage 与 startTask 同属 BasicSkill，进入 Gateway ChannelScheduler，委托等待接纳而不等待 Writer 创作结束。Writer 保留独立上下文、工具库、模型工作流和 Gateway direct Tool。Writing 的作品管理入口也改为 XML Action，避免动态加载后再次混入原生工具。

Actions 生产装配分别投影 scheduled Action 与 direct Tool，同一业务函数可按协议共享实现，不修改 Gateway/调度器设计。补齐 Basic/Writing XML 示例、单任务/追问/取消规则；Assistant 身份提示明确可委托的 Writer 职责及其他运行时 Agent 的边界，不把通信授权表当作模型可自由调用的 Agent 目录。验证所有 Assistant Skills 仅提供 Action、默认与动态目录无模型 tools、委托经真实 Scheduler 完成接纳、Writer 继续 direct，并检查提示词容量与现有回归。

双向角色说明：Writer 控制提示词同样说明委托来源 Assistant，以及 ask/finish 经宿主回报 Assistant、由 Assistant 向用户沟通；不向 Writer 注入 Assistant 私有上下文或 XML 协议，不让内容生成请求承担跨 Agent 通信。

XML/调度修正及双向职责教学已落地，自动化与构建结果见 docs/validation/Writer-Agent.md 的“Assistant XML 与调度边界修正”；真实模型/真机交互仍属于独立待验收项。

## 智能体大脑设置（2026-11-03）

设置“大模型”改为“智能体大脑”：Provider 管理列表（名称/URL、末行添加、原生左滑编辑/删除），Assistant 与 Writer 各自 Provider/模型联动菜单，最后本地模型资源。取消全局云端开关；每个 Agent 的 Provider 包含本地选项，选择本地隐藏模型菜单。页面进入和 Provider 选择/凭据编辑自动发现模型，保存前不改变运行配置。发现结果按稳定 Provider ID 与凭据快照隔离，保留已有模型选择，失败允许显式重试；至多 32 个在途查询，离页取消、根关闭加入。

cloud/providers 保存 Assistant 当前选择与 Provider 列表，writerProviderID=nil 表示本地，不继承 Assistant；删除 Provider 将引用它的 Agent 改为本地，编辑保留 Provider ID。配置和 Key 仍走现有事务/钥匙串，无新目录或数据库旁路。UI 只拥有草稿和模型列表，查询仍经 ApplicationControl/Gateway，由返回值交给表单控制器按 Provider 投影。

ModelKit 提供角色无关的思考策略（最低/允许推理）和独立本地 ChatLease；Actions 分配 Assistant 最低策略、Writer 允许推理。已知支持关闭的模型关闭，不支持关闭的已知推理模型选其最小档；Writer 不发送关闭参数。未知兼容服务不伪造能力，服务错误显式返回。Gemma 本地能力遵循实际设备支持，不能伪装原生工具可用。验证独立保存恢复、删除/编辑引用、双列表加载与过期结果、模型请求思考参数、租约隔离、UI/build/check；真实云端与本地模型单独记录。

智能体大脑配置/表单改造已实现，验证与本地 Writer 能力限制见 docs/validation/Provider-Management.md 的对应章节；真实 Provider 与原生交互仍待独立验收。

### 设置操作反馈修正（2026-11-03）

在现有 SettingsView 内将 Provider 删除改为原生确认 alert，明确取消与删除；确认前不修改草稿。保存等待实际回执后在页面显示成功或失败 Toast，替换常驻状态行，保留保存忙态和原业务事务。Toast 单槽替换、自动到期，页面离开取消展示计时，不取消根拥有的保存。同步 Settings README 与 Provider 验证记录；执行项目检查和 iOS 构建。

### 委托超时与残留状态修复（2026-11-03）

真机记录 task_135 委托 Action 超时，SQLite 随后写入 CancellationError。检查发现 Agents Support 的输出轮次屏障停止读取通信，Action 等通信回执形成环路。拟在 IndependentOutputWorkflow 将通信分流提升至跨轮次的独立消费者（有界队列、关闭加入），保持 XML Action/ChannelScheduler/Gateway 契约不变。测试移除 Writer 委托场景的通信替身，验证真实输出、失败/完成、再次委托及历史归档。startBackground 将注册纳入清理范围，内存与持久化失败独立收尾并保留清理错误。灵动岛 Writer 终态明确展示失败/完成文字；不将结果保留误呈现为运行。同步 Support/Chat 与 UI Runtime 文档、记录验证证据。

## 按委托任务组织历史与作品（2026-11-03）

实施已确认计划：共享 SQLite 中增加长期委托任务与执行关联，稳定 taskID 对应 Writer 对话和独立 StorageFiles 项目，每次执行使用新 runID。现有 tasks 行表示执行，新增关联记录保留原目标与项目；来源 Assistant 对话采用可置空关联。续作重新激活原 Writer 对话；强制替代先取消并加入清理后再接纳。模型上下文从本任务历史恢复，工具调用仍保存原生结构。Writer 设置入口改为分页任务列表，详情展示请求与原生工具，菜单分享记录/显示文件，文件支持预览及现有导出。所有代码在现有目录内完成，更新 Storage、Agents/Writer、UI/Settings、Actions/Artifacts 和整体文档；执行完整检查、iOS 构建并区分自动化和设备验收。

工作区初始化失败补充：项目身份在调用 start 前先通过 Storage 绑定，记录 workspaceReady；尚未就绪的同一预留 ID 可幂等建立目录，窗口成功后再确认 ready。窗口呈现失败保留相同任务/项目身份和已有草稿；已就绪目录丢失必须报错，不自动创建替代项目。Artifacts start 的内部 createProject 参数只用于受信运行时，模型工具循环不接受 start/resume。补测窗口首次失败后续作仍使用同一目录。

任务组织实现及自动化验证已完成：稳定任务/执行分离、SQLite 迁移、续作与强制替代、任务历史及关联文件预览/导出均已接入；初始化失败保留预留目录身份，模型取消与运行时中断不误标用户取消。完整检查和四目标 iOS 构建通过。原生交互、真机及真实模型验收尚未执行，证据与限制见 docs/validation/Writer-Agent.md。

## 使用模型默认输出预算（2026-11-04）

移除 Writer 控制请求的2048 token、内容请求的16384 token，以及会话标题请求的64 token覆盖；Assistant 原本不设置输出 token 上限，继续保持。OpenAI Responses 适配器删除显式输出预算不得超过32768的自设校验；maximumOutputTokens=nil 时不发送 max_output_tokens，由服务端使用模型默认值。保留中立接口对显式正整数预算的透传能力，不把某款模型的上限硬编码为所有模型的上限。增加 Writer所有实际请求默认nil和云端不注入预算/不拒绝大显式预算的回归，同步技术文档并运行完整检查和iOS构建。

同一默认规则也用于显式聊天诊断请求，移除其32-token覆盖；模型加载内部的一 token 预热不属于用户生成请求。

## 开发期清空旧存储及移除兼容（2026-11-04）

按用户明确要求，旧版 Writer、Assistant 及其他历史全部舍弃。SQLite 合并为一个当前 schema，不保留 v1...v5 升级链或 Writer 旧历史归组/只读模式；旧 schema 在初始化发布前整体清空并重建，当前 schema 的正常重开、崩溃恢复和事务保持。明确清空已连接开发真机与模拟器的应用 SQLite（含 WAL/SHM），不以迁移保留旧消息。

审计并移除其他持久格式兼容：Provider 旧 Keychain 记录导入/单 Provider 文档兜底、资源偏好旧单开关、模型安装路径/下载快照修复、Artifact 缺省入口及旧可选索引数组、ActivityKit 旧快照字段解码。保留真实可选观测、当前空值、协议版本校验、取消/崩溃恢复与硬件/Provider 协议支持，不能因关键词 legacy/compatible 误删现行功能。更新相应测试为当前格式往返、旧格式拒绝/旧库重建，更新所有受影响技术文档和验证记录，不新增模块或目录。

清理实现及自动化验证已完成；当前格式重开不清空，旧格式不导入。模拟器已完成清空与重开核验。真机覆盖安装完成，但新进程启动被 iOS Locked 拒绝，旧库清空尚待解锁后启动并核验，不把安装成功作为数据已清空的证据。详细检查结果见 docs/validation/Writer-Agent.md。

## Writer 容量误报与重复委托修复（2026-11-04）

真机 task_138/139/140 在模型启动前失败，workspaceReady=0，错误均为 capacity；Assistant 收到终态又输出同目标 delegateTask。现行 Artifacts checkpoint 在已有8个作品身份后拒绝新建，且旧作品/失败草稿不会因 SQLite 重建消失，造成正常创作被人为配额阻断。

本次移除 Artifacts 的8作品、16版本、32文件、64KiB单文件/流和256KiB项目限额，以及 Writer 内容接收器的64KiB截断；不自动删除旧作品或版本。文件路径/所有权/事务校验、分页与读取引用、并发窗口和队列的有界准入、Storage 现有文件/文档存储容量与实际 I/O 错误保持。预览/版本读取/导出入口取消额外源码大小门槛，使用受控 Storage 文件边界，不能产生写入成功但仅因更小预览限额无法打开的情况。

Assistant 对 Writer 正式事件只向用户汇报或提问，delegateTask 只接受当前真实用户文本/最终语音输入，禁止从 failed/completed/userInput/cancelled 事件启动新委托；用户的新输入仍可显式续作或重试。补齐 Basic 与 Writer 事件提示。Writer 对同一未修正的失败工具参数不再次执行；成功编辑/恢复/移动等改变草稿后允许重新验证，读取/搜索不能清除失败屏障。参数错误返回可修正的信息，不将永久配额/存储故障当成盲重试依据。

涉及 Actions/Artifacts（草稿、版本、呈现和导出）、Agents/Writer（流与工具失败流程）、Agents/Support/Chat（委托来源校验）及对应提示/README。回归覆盖超过8个作品、超过16版本、超过64KiB源码流与发布/版本读取、失败后原样调用只执行一次、修正后允许继续、Writer失败通知不能再委托而新用户输入可委托。执行 check.sh/build-ios.sh，并单独记录真机及真实模型验证范围。

修复补充：每项真实用户输入只允许一次实际委托尝试；参数/busy校验尚未委托时可修正，已经发起的委托无论接纳或失败都不能在同输入中重复创建。Artifacts 参数/引用/上下文/撤销点错误使用具体原因和修正提示，不再统一返回 capacity。

大文件/多文件开放后的导出校验：现有 ZIP 写入器是标准 ZIP 而非 ZIP64，导出前依据格式字段宽度校验数量、字节长度和偏移；不能因移除业务配额引入 UInt32 转换崩溃或生成截断 ZIP。此为导出格式边界，不限制创作或模型输出，超格式范围建议分享单文件。

模型输出预算一致性：同时移除 Writer 控制请求纯文本响应的4KiB字节截断；控制与文件内容都保留 Provider 默认生成长度。工具参数/上下文分页是宿主协议边界，不能当作模型响应大小上限。

容量及重复委托修复已实现并覆盖安装真机；完整 check、四目标 iOS 构建和最后输出/ZIP 回归通过。真机锁屏阻止启动，真实模型及交互验收未完成；验证证据见 docs/validation/Writer-Agent.md。

## 真机 HTTP/传输失败取证与 Writer 分类诊断（2026-11-04）

真机当前 schema SQLite 完整性正常。首个 Writer task_1（qwen3.8-max）已完成工作区初始化，第一轮控制请求调用 list 成功；第二轮控制请求无文本/工具输出，在60.03秒后以 code=transport/stage=http失败，整任务64.45秒。旧网络层把所有非已知错误折叠为 transport，未保存 URLError，不能从旧证据断言具体底层原因；与 timeoutIntervalForResource=60 整段传输限制高度吻合，不是已证实的HTTP状态错误。

网络适配器移除由聊天 timeout 派生的整段资源时限，将该参数用于 URLRequest/URLSession 空闲等待；使用 URLSession 默认资源期限，保留取消及 Agent 任务生命周期。保留明确的网络错误数值及分类（timeout、DNS、TLS、连接、离线、取消、未知）、收头/流式阶段；HTTP错误保存状态、请求ID和服务端结构化错误的 code/type/param 以及有界脱敏 message，不保存原始响应体、URL或凭据。不隐式重试/换模型，也不调整生成预算。

Writer 在原请求/工具/执行链保留阶段、实际模型、请求输入ID、耗时及分类诊断；清理异常与原始错误分别保留。Storage Chat 现有 evidence 增加中立可选 failureDiagnostic，不新增数据库或迁移；历史不伪造旧缺失证据。WriterTaskEvent 携带同一诊断，Assistant观察可获知事实并给用户准确汇报；任务终态字符串包含明确摘要和代码。UI只消费通用诊断 DTO，在 Writer 请求详情显示分类、阶段、信息、诊断字段及清理原因；不依赖 Agents 或 ModelKit。

修改范围：ModelKit/Language/LLM 及 OpenAI 网络叶目录；Agents/Writer、Support/Communication/Chat；Storage/Database/Chat；UI/Settings 和相应技术README。允许在既有目录增加具体实现文件，不新增目录/模块，不改Gateway调度。自动化验证 URL错误分类/HTTP信息脱敏、有效持续流不被整段timeout取消、主动取消、Writer 失败事件与SQLite重开还原、模型/阶段/耗时/清理原因、UI DTO投影。执行 check.sh/build-ios.sh，真机真实模型验收单独记录，不猜测旧请求已丢失的网络根因。

边界细化：Writer 通信诊断值由 Agents/Support/Communication 自己拥有，不导入 StorageChat；Writer 目录显式转换为 Storage 的中立诊断值，UI继续使用自己的只读DTO。Xcode导航组同步新增实现文件引用，保持现有SwiftPM编译边界。

Assistant观察投影遵守现有4KiB输入边界：优先保留任务身份、错误分类/代码/阶段及关键网络/HTTP事实，过长说明显式标记截断；完整结构化事件和Writer请求证据仍保存在SQLite，不能因错误信息变详细而拒收终态。

## Writer 自主任务及汇报／聆听衔接核对（2026-11-04）

用户补充的目标：delegateTask 接纳后任务与 Assistant 解耦；Writer 自有模型、上下文、工具、文件增删改查、显式运行/渲染及完整 loop，Writer 决定正常完成，Assistant 只接收其工作汇报并面向用户回复。Writer 汇报到达时若已有回复，应等当前整条回复实际播报完成再衔接；聆听或非聆听状态均可响应，非聆听状态下播报完成后自动启用聆听。新的用户明确停止/打断命令仍应按其时序处理，不让旧恢复动作覆盖更新的用户意图。App/系统生命周期仍由应用根拥有。

本次为源码审计，未修改运行代码，也未将以下缺口写成已实施设计：

- 已有独立 WriterWorkflow、ChatLease、原生 Tool/Gateway direct、文件/版本/渲染能力，正常 finish 由 Writer 选择，Assistant 不参与源码循环。Writer 不等待其创作期间 Assistant 的推理/播报完成。
- 正常 Assistant 推理轮次经 roundFinished/actions.finish 等待真实播放完成；Writer 输入使用同一FIFO，当前worker结束后继续处理。尚无跨所有回复占用的统一 Writer 通知播报交接入口，且此前接纳的其他输入会排在 Writer 前，不能把现行FIFO称为无条件下一条插入。
- WriterTaskEvent.requiresReply 排除了 started/progress，只对 userInput/completed/failed/cancelled 触发 Assistant。普通工作汇报目前只更新状态，与新要求不一致；需要由 Writer 组织需要播报的有意义阶段，接收侧按正式输入处理。
- listeningPolicy 的 enabled 独立于 paused，ReplyActivity 只更新回复占用。finishPlayback 在无 voiceGeneration 时直接返回，不会从非聆听自动启用；enabled=false 的策略更新另有 stopVoice/cancelReply 路径，应与主动任务汇报的允许播报/播毕开听语义明确区分。
- 普通 interrupt 路径已排除 Writer；Assistant 完整close路径仍会向同会话Writer任务发送取消。Writer start 和部分工具步骤还同步await汇报接纳，投递失败可传播为创作失败。完整任务独立要求这些汇报生命周期与创作生命周期分离，保留有界失败/待送达证据而不因Assistant暂不可用误终止创作。
- 汇报仍绑定 originDialog，切换对话后只更新状态，不触发当前对话回复；这是此前隔离要求的实现，新的应用级汇报入口需要明确保留来源身份并与对话历史关联解耦，不能泄露其他会话私有上下文。
- Writer 仍有24控制/24内容请求和10分钟预算（跨等待/恢复共享），这些是Writer内的固定终止条件；正常完成自主不等于当前循环没有硬停止规则，后续修改需明确其政策。

后续实现应在现有 Writer、Assistant 输入/回复工作流和 SpeechPerception 聆听政策内修正，不新增调度器或模块。Writer 通知不直接操作麦克风，聆听启停仍走已有角色与Action/Gateway；无需为了每次汇报强制进入新的前台Task。验证重点应为真实播放排空、跨角色回复/排队、非聆听汇报与播毕启听、显式停止的时序、停止Assistant会话但Writer继续工作，以及通知投递失败不重跑/误失败创作。本次只完成审计与需求记录，未执行新增运行时验收。


### 自主任务与汇报衔接实施范围（2026-11-04）

按最新确认开始实现。WriterWorkflow 删除固定控制/内容轮数与整任务期限，由模型 finish、真实失败、明确取消或应用根生命周期结束；保留上下文裁剪、工具配对和重复失败屏障。WriterAgent 在现有目录内持有独立有界消息投递 worker：同执行每种阶段最多一项待送达消息及一项在途消息，普通进度合并为最新事实，追问及终态保留原 eventID 重投；投递失败单独展示，不传播为创作失败、不重跑文件效果。暂停加入投递 worker 后恢复，根停止加入并记录无法投递原因。保持单任务接纳及取消清理确认契约。

Assistant 关闭/打断不自动取消已委托 Writer。汇报不再要求发起对话仍为当前对话；仅将受认证的目标、作品、工作事实加入当前 Assistant 输入，保留来源对话身份，不读取旧对话私有上下文。started、实际文件提交/渲染等阶段和追问/终态均作为正式输入；仍遵守已接纳输入 FIFO、32项容量与去重，不将新通知插到先接纳的最终语音前。Writer 输入等待当前模型/真实播放及前台委托回复收尾，回复占用解除即继续 drain。

在现有ReplyActivity业务值增加最近成功Writer汇报的身份与开始时刻，只有认证Assistant可提供；完成事实随完整快照保留，SpeechPerception据此拥有一次性播毕启听意图，乱序接收不依赖先收到开始快照。非聆听时的单纯占用变化不发送关闭/取消播报 Action。成功回复实际播放屏障结束后通过已有聆听政策/Gateway 启听；明确停止、采集中断、暂停/根关闭撤销该意图，重复/过期完成不能重新启听。失败或被取消的回复不启听。无需模型产生 startListening，不改变 Gateway、ChannelScheduler 或基础模块接口。

修改文件：Agents/Writer 的 Workflow/Agent/Diagnostics、Support/Chat/AgentChatWorker、Support/Communication 的 AgentTasks/SpeechValues、SpeechPerception 的 policy/agent，相关 Instructions、测试和 README；总体设计同步跨角色流向。验证覆盖超过24轮仍可 finish、取消、拒收开始/进度时创作仍完成且同事件重投、暂停恢复、Assistant关闭仍保留Writer、跨对话汇报、排队/前台回复实际收尾、非聆听播毕启听与停止优先。执行 check.sh、build-ios.sh，真实模型/原生UI/真机交互单独记录。


满队列汇报验证补充：启用真实ReplyActivity发布并连续接纳32项输入时，逐项发布同态busy完整快照可能淹没独立通信消费者。拟在Chat拥有的发布端只发送占用进入/退出、当前最终语音root确认、会话变化及新的成功汇报事实；每次发送仍是完整快照，不增加队列容量或修改通用Gateway/调度。普通同态输入变化合并，最终语音确认不能被合并掉。验证保留32项满载用例，不通过缩小测试输入规避。


自主任务与汇报衔接已实现：独立创作/投递worker、移除固定循环/期限、所有阶段正式输入、Assistant close不取消Writer、跨对话事实汇报、当前真实播放及peer回复收尾后FIFO接续、播毕启听与停止围栏均已接入。满队列同态占用发布修复未扩大队列或修改Gateway。完整自动化和四目标iOS构建通过；最终细节和模拟器/真机验收边界见docs/validation/Writer-Agent.md。真实模型及真机语音/窗口并行交互仍需独立验收，不能以替身/构建作为通过证据。


### 独立占用复核与本次安装边界（2026-11-04）

复核确认：创作、模型/文件清理和SQLite终态不等待Assistant接收或播报；但WriterAgent.requests仍在终态事实被接纳后才移除，因而消息持续拒收时会保留任务占用并拒绝后续委托。完全独立的占用释放尚未实现，需与待送达通知生命周期分离；不能将既有单任务传输确认边界称为完全解耦。本次按用户要求安装当前代码，未在安装操作中修改该逻辑。

### 完全独立的任务占用与终态通知（2026-11-04）

实现剩余耦合修复。Writer 在模型/文件清理完成后自行结束创作占用，任务终态与待送达终态通知在既有 TaskRepository/SQLite 单次事务保存；通知是否接纳、模型回复或播报均不参与创作准入。新的/续作委托仍只有一个实际创作任务，等待输入/暂停/取消清理仍占用。

终态分为两条现有 Gateway 通信链：task.result 只负责执行身份退休及控制状态收尾，不占 Assistant 回复队列；新增 Writer 业务终态通知契约承载同一 AgentTaskSignal 业务事实，由 Gateway 的通用角色消息通道认证递送，不依附已经退休的执行权限。普通运行进度与追问继续使用原 task.progress；任务结束后停止重投这些过期步骤。此为 Agents 业务契约扩展，不修改 Gateway/ChannelScheduler/AgentCore 调度设计。Assistant 的 busy/取消替代判断读取可信任务执行状态进行对账，不能等待用户通知或旧 taskView。强制替代等实际清理终态，清理失败拒绝替代。

StorageTasks 增加中立的任务终态通知值、按执行查询、原子完成/入箱、分页读取和投递确认/失败证据；SQLiteTaskRepository 拥有同一数据库的通知表，运行时每个投递分支最多取32行，持久积压不限制创作次数、不丢弃终态。执行退休和用户通知使用独立投递 worker，避免拒收通知阻塞退休；按页轮转重试，保留 eventID。当前 schema 的通知表幂等建立，不导入旧协议、不清空当前历史，不新增数据库/目录/模块。进程重开只恢复通知投递，不重跑创作；退休的旧执行不能重新授予文件权限。

Assistant 验证认证 Writer 来源及 SQLite 中的 taskID/runID/终态通知绑定；持久去重以通知确认和已提交聊天输入身份为证据。新契约仍按32项 FIFO 接纳，满时拒收，由通知 worker 重送。旧执行通知不能覆盖续作状态；已结束任务的迟到普通进度不再触发问答。新根会话中的通知回复使用当前 Assistant 交互身份，仅携带任务事实，不读取来源对话私有上下文。删除已替代的 writerConfirmations 及终态先入回复队列再等待 result 的屏障。

文件范围：Storage/Database/Tasks、SQLite、Chat 的领域接口/适配；Agents/Writer、Support/Communication/Chat、AgentContracts、Assistant/Writer资源配置及相关README/总体设计。测试覆盖通知持续拒收时Writer空闲并能连续新建/续作（超过旧后台执行16项容量）、退休/通知两分支独立、满队列/重开/去重、取消替代/清理失败、迟到旧消息不覆盖新任务、SQLite当前数据保留。完成后执行check.sh和build-ios.sh，分别记录替身、模拟器及真机/真实模型边界。

存储验证还覆盖终态更新与通知插入的事务回滚、不可变载荷冲突、Agent 查询隔离、独立退休/送达标记和重开还原；不得将通知写入失败隐藏为成功。

完全独立占用的代码与文档已对齐。自动化已验证持续拒收时连续创作、旧状态对账、新建/续作迟到消息、同事件重送及进程重开仅投递，并覆盖通知与终态的原子回滚和Agent隔离。完整检查和最终补强回归通过；iOS构建、安装及真实模型/语音交互证据分别记录在docs/validation/Writer-Agent.md，构建或安装不替代实机交互验收。

最终串行build-ios.sh四目标通过；真机签名构建、资源/签名检查、覆盖安装和启动通过，安装序号5836。完整证据及首次并行构建失效的记录见验证文档；真实模型与真机语音/绘图交互不作为本次已完成验收声称。

### Writer 自有灵动岛呈现与 UI 状态编排（2026-11-04）

WriterAgent 根据自身接纳、工作区就绪、实际步骤、等待输入、暂停恢复、取消清理和终态发布灵动岛内容，不再通过 Assistant 通知、Task 日志或 IslandDomainPresentation 推断。删除 Actions/UI/Runtime 中 writerContent 的日志投影，普通前台任务继续排除 Writer。Writer 域新增展示适配文件（既有 Writer 目录内），内容、紫色身份、简短目标与阶段摘要由 Writer 拥有；同一角色根的稳定活动身份跨委托复用，每次新 run/等待/终态改变 expansionID，普通进度尊重手动收起。长目标/步骤仅按 UI 展示契约投影，不截断模型或持久历史。

展示通过现有内部 UI.Island.present Tool 经 Gateway direct 执行，不进入 ChannelScheduler，也不暴露给 Writer 模型。使用独立于委托会话和已退休任务权限的呈现上下文；Writer 域独立有界 latest-value worker（一个在途、一个最新待投递内容），串行 revision 和 run 围栏阻止旧状态覆盖新任务。拒绝或暂不可用保留明确失败并重投最新事实，不影响模型、文件、终态持久化或新委托；根停止取消并加入展示 worker。通知重投不触发 UI 重放，Assistant 完全不负责 Writer 展示。

UI Island 继续拥有多来源状态中心的双区域仲裁、布局、可中断动画、收起偏好和系统投影。IslandContent 的任意数字 rank 改为 UI 自有通用语义 priority（background/low/normal/high/attention/critical），优先级顺序由组件定义，同等级按最新实际内容排序；详情与实时状态独立选择，语音顶部可与 Writer 详情并存。更新现有领域生产者及测试到当前字段，不保留旧 rank 解码。动画数值与几何不下放给业务。此为组件内容接口调整，不修改 Gateway、ChannelScheduler 或基础框架。

涉及 Agents/Writer、Actions/UI/Runtime、UI/Components/Island、现有角色能力声明/Xcode导航及相关测试；实现后同步这些 README、Agents/UI/Actions 模块和总体设计。验证：Assistant 拒收全部通知仍实时显示开始/步骤/完成；展示暂不可用不阻塞创作，恢复只显示最新状态；新任务/续作不受旧回调影响；等待/失败/取消/暂停状态；语音并存、手动收起、新阶段展开、语义排序、真实动画回执围栏和根清理。运行 check.sh 与 build-ios.sh，真实模型/原生UI/真机验收单独记录，不以替身代替。

本节已实现并同步技术文档：Writer 自有任务岛通过内部 Gateway direct Tool 发布，日志反向投影删除，UI 语义优先级及既有动画/布局归组件统一拥有。脚本模型下真实 Gateway/Island Actions/UI 状态验证通过，完整 check.sh 与四目标 build-ios.sh 通过。真机安装、真实模型与原生动画交互未作为本次通过证据；详见 docs/validation/Writer-Agent.md 对应章节。

### 真机 task_5 调查与 Writer 有限恢复循环（2026-11-04）

真机只读复制 SQLite base/WAL，校验当前 schema20261104、integrity_check=ok；task_5 两次控制请求成功（list、edit index.html），文件内容请求仍 generating，任务 running，未取得其终态失败证据。task_4 的已保存终态为 modelResponse / writer.model.stream.limitExceeded / framing。不能把 task_4 的错误当作 task_5 已证实错误；继续跟进 task_5 最新快照。临时数据库副本只用于调查，结束后删除，不清空设备历史。

参考 deepseek-ai/deepseek-harness（master8bd073392eef6f54e921a093b95076248eb08cbb）的 core/agent-loop/src/agent.ts、assistant-stream.ts、fs/tool-fs/src/edit.ts、write.ts、error.ts 和 guard/repeat-tool-reminder/src/index.ts：请求 attempt 与成功模型消息分离；批次异常补齐未处理工具结果；编辑提供明确重读/修正提示；重复调用先向模型反馈而非立即杀死整个任务。保留本框架的无 shell Storage 沙盒、原生工具控制与独立源码流；不搬入其调度/插件/Skill框架。

Writer 域新增有限恢复策略（既有目录内）：可恢复模型网络/暂时性 HTTP 错误，每项请求最多3次尝试、可取消退避；永久配置/鉴权错误、用户取消、历史/文件存储及清理失败不盲重试。控制响应缺少工具、无效结束批次等在没有执行效果时反馈修正，最多3次恢复；工具错误返回分类/修复建议，未改变草稿的相同失败调用不再次执行效果，但允许有限模型修正轮次，达到上限才结束。成功草稿修改推进恢复阶段；不限制正常有进展的创作总轮数或任务时长。

内容请求失败必须先加入 abort，保留可恢复草稿；确认事务清理后才用新 stream 身份重新生成，最多3次，不向原 stream 重复追加。提交/保存结果不确定和 abort 失败立即保留原始/清理错误结束，不能重放已提交文件副作用。原生工具批次的所有调用均保存成对结果，包括未执行的兄弟调用和失败证据；失败请求和后续请求各自有真实 SQLite 请求记录。重试状态由 Writer 发布到自有岛/进度，Assistant 不重新委托、不参与恢复决策。最终诊断保存尝试次数、恢复种类和最后原因，只在恢复耗尽或不可恢复时报告失败。

ModelKit/OpenAI 移除累计响应及 SSE 行/帧的生成大小截断，保留当前协议校验、原生工具参数边界和有界背压事件队列。较大的文本 delta 切成有效 Unicode 增量再交给队列，单事件缓冲边界不成为输出总量限制；Provider 默认输出预算不变。Decoder 缓冲按帧释放，异常 UTF-8/JSON/完成语义仍明确失败，不引入自动模型切换、降级或通用框架重试。

修改范围：Agents/Writer 的工作流、恢复策略、诊断/历史与进度接口；ModelKit/Language/LLM/OpenAI 的 decoder 及 owning README；现有 Writer/Provider 测试、Xcode源码导航和相关模块/总体设计文档。验证短暂错误恢复/耗尽、永久错误不重试、文本-only控制纠正、重复失败调用抑制后恢复、部分源码中断后的新事务、清理/提交失败不重放、完整工具配对、取消退避、超64KiB帧/超8MiB流及 Unicode 完整性。执行 check.sh、build-ios.sh，替身、真实模型、安装/设备交互分开记录。

补充调查结论：最后只读base快照已经保存task_5终态failed（431.982s、writer.model.stream.limitExceeded、framing）；message204保存15,379字符/16,237 UTF-8字节并以</html>结束，未有有效完成事件。对base使用immutable只读校验通过，终态不依赖后续网络失败的WAL传输。已证实为应用流解析限制，但旧诊断无法区分具体累计/行/事件阈值。继续保留全部任务和草稿，不自动重跑失败任务。

本节实现与技术文档已对齐：SSE生成截断移除、Writer三次尝试及退避、原生工具修正/完整配对、新stream恢复与清理/提交不重放均已接入。完整check.sh及四目标build-ios.sh通过；设备原始任务保留，没有自动重跑task_5或安装新版本。真实Qwen续作与原生交互另行验收，具体证据见验证记录。

### 本机 Writer 双模型多流程回归（2026-11-04）

新增显式启用的真实模型评估，复用 Assistant 多 case 回归的凭据隔离与逐 case 落盘方式。scripts/evaluate-writer.py 仅读取 .env.local 的阿里 Provider 配置，向独立测试进程传递凭据，分别运行 qwen3.8-max、deepseek4.1-flash；不输出密钥、不设置模型输出上限、不修改生产模型选择。Tests/IntegrationTests/WriterModelEvaluationTests.swift 运行生产 WriterAgent、Gateway direct、ArtifactService、StorageFiles 和 SQLite，使用本机 WebKit 执行 HTML/JS、校验本地资源和脚本错误；不将无截图的验证描述为视觉验收。

场景覆盖简单流程图、多文件 HTML/CSS/JS、续作局部编辑、目录查询/移动/删除、Markdown，以及连续新建与旧任务续作。评估记录每次请求的阶段、开始/首输出/结束耗时、文本字节、工具调用、usage、错误分类，保存完整 SQLite 证据和作品；每 case 完成立即保存结果。付费实验单独设置请求次数和等待期限，超限明确标记评估中断并取消/加入 Writer，不作为生产预算，也不冒充模型或正常任务失败。报告区分 Provider 错误、原生工具协议、文件事务、渲染、创作循环及测试期限。按轨迹发现实现缺陷时先补充本计划再修复和复测。

实现后同步 scripts、IntegrationTests、AgentModelEvaluationTests README，在 docs/validation 保存双模型逐 case 结果与限制。执行 check.sh、build-ios.sh；本机真实模型/WebKit 不替代 iOS 真机语音与 UI 验收。

真实模型首轮补充：Provider /models 确认用户所指 DeepSeek 的实际标识是 deepseek-v4.1-flash；deepseek4.1-flash 不存在，Responses 仅返回 server_error。评估入口应先验证精确模型身份，明确输出映射，禁止凭不明确标识反复执行整组任务。

DeepSeek 真实工具轨迹发现 start/end 被生成为 CSS 选择器文本，且简单流程图在渲染成功后不断为未请求的副标题/间距/缩进做局部美化。拟在 Writer 自有 schema 为每个参数提供就地说明和命令/预览枚举：字符偏移只能是十进制数字字符串，优先使用 read(line,limit) 返回的范围，不传字符串锚点；在控制与内容指令同步要求最小满足目标、保留范围外内容、检查通过后finish，避免未要求的样式打磨。不改变框架协议、全局循环预算或 Provider 输出默认值。增加生产 schema 与指令行为回归，保留修复前真实轨迹作为对照。

进一步确认 DeepSeek 首个 HTML 内容响应使用外层 ```html 包装，宿主将其原样写入HTML；后续模型为清理包装不断局部重写，进一步破坏片段并消耗大量请求。拟增加 Writer 域的流式内容前缀校验：仅 HTML/CSS/JS/JSON/SVG 拒绝开头的三反引号外包装（跨 delta 校验），不剥离/猜测源码；Markdown/TXT 保持原内容。拒绝发生在提交前，使用现有 abort→新stream→有限重试，重试请求附明确格式修正提示，最终持久化专门的内容格式错误。记录真实响应原文，不将模型协议违规错误归因于磁盘容量。测试验证跨分片、UTF-8、合法JS模板字符串、Markdown代码围栏、不提交错误包装和重试成功/耗尽。

文件移动用例另发现模型在finish额外传verification字段，CapabilityRegistry明确拒绝invalidParameters，但Writer未转成可纠正的工具结果，直接作为未知runtime异常结束。拟仅在Writer绑定处将执行前参数校验错误转换为带未知字段名/validationCode的WriterToolFailure，由既有有限修正循环接管；不忽略非法字段，不修改通用CapabilityRegistry，也不重试已发生的副作用。局部编辑的宿主context明确选区首尾换行属性，内容指令保留选区分隔符，避免片段吞掉换行引起无意义格式重写。

全量检查发现既有 WriterIsland 重试用例在并发负载下以“调用次数≤3”推断latest-value合并，而其500ms重试本身允许多次失败，造成时序误判。测试拟以明确的首调用挂起/释放门控制发送阶段，验证一个在途+最新待送达、新run围栏和stop加入；不修改生产重试频率，也不放宽语义断言。该调整只提高回归的确定性。

双模型复测再次出现局部片段丢换行→排版修复循环，仅依赖自然语言内容请求不足以提供现代代码编辑器的确定性修改。参考已核实的 DeepSeek Harness 唯一literal匹配机制，在既有 Writer/Artifacts 增加 replace(path,reference,oldText,newText)：必须为当前文件的新鲜read引用、oldText非空且在引用范围内唯一；只替换匹配文本，范围外逐字节保留，空newText表示删除。歧义/无匹配/过期引用明确返回修复错误，失败不改草稿。沿用现有native参数边界，不扩展大源码工具传输；Writer控制工具允许短literal补丁，新建/大段内容继续单独流式生成。成功replace清除有限修正阶段并需要重新render，所有副作用仍经Gateway direct。新增原子性/歧义/跨文件引用/Unicode/删除/持久工具轨迹回归，再按相同多流程复测。功能归Writer域与既有Artifacts业务，不增加框架接口/调度/目录。

双模型多流程与确定性编辑已实现：最终未变源码/二进制矩阵两模型各6/6通过，Qwen约356.5s、DeepSeek约137.8s，99次真实请求均使用Provider默认输出预算。新建目录、续作task/run/dialog、完整native配对与SQLite重开、实际WebKit错误修复及点击均验证。新增独立验证文档和机器结果/请求轨迹保存于docs/validation/Writer-Model-Regression*；前轮失败、主动中止与模型ID修正保留，不能改写成首轮即成功。完整check与iOS构建证据在该报告收尾更新，真机/原生语音仍独立验收。

本次最终交付检查：完整check.sh exit0、四目标build-ios.sh exit0、真实双模型12/12、本机WebKit预检和SQLite重开通过；首轮/第二轮失败及并发时序重跑证据已完整记录。报告/轨迹与源码哈希校验通过且未包含凭据。本次未安装真机；既有真机验收目标仍由原计划单独跟进。

### 快速完成、持续预览与任务记录（2026-11-04，已确认实施）

按用户确认实施：Writer域拥有750ms latest-value预览worker（一个在途+一个最新请求），通过Gateway direct内部preview读取安全检查点；源码追加不等待页面。替换Artifacts原append/complete同步预览路径，保留200ms草稿落盘。脚本仅完整render执行；render/finish/取消/暂停/关闭加入预览，run围栏阻止旧帧，窗口关闭/最小化不重开且不重试。正常无工具终止进入统一finalize，使用同一finish业务校验与Gateway提交；准备不足反馈修正，提交/清理不确定立即失败，运行时效果独立留证不伪造provider tool。收尾前处理已接纳补充。

每个模型attempt记录身份、跨run累计轮次、phase/attempt/path，实际调用前报告并更新自有岛；Writer完整SQLite请求为全量事实。Assistant普通进度保留一个最新摘要，空闲且既有正式FIFO排空后接纳，普通播报间隔10秒；追问和终态保持32项FIFO/持久重投，终态清除未接纳普通摘要，拒收和播报不影响Writer。提示词以尽快满足实际目标并结束为原则，不添加非必要动画/装饰、不反复读取刚生成文件或重试不可见窗口。

UI Settings拆为Assistant聊天记录和Writer任务记录，删除聚合页；WriterTaskItem增加startedAt/requestCount，Storage既有仓库提供中立计数与摘要查询，不新增数据库或清空数据。Writer轻量请求分页替代全量源码轮询；详情顶部目标/开始时间/状态/文件与导出按钮，下面按每次请求计轮的图标条目和run分隔，完整请求仅按需读取。维持文件PDF/ZIP能力。

涉及Writer/Support.Chat/Communication、Actions.Artifacts、Storage.Chat/Tasks/SQLite、UI.Settings/Root、导航Actions/示例及测试/README。新增文件仅用现有目录。验证慢模型早期画面、无背压、合并/旧run/取消、请求事实/进度FIFO、自然结束/失败/补充、分页统计/重开/布局。真实双模型使用原始简单目标，记录首画面/间隔/轮次/延迟与历史task_6对照；执行check.sh、build-ios.sh，模拟器和真机结果单列。

实现细化：正常无工具响应的收尾以独立finalize端口执行同一Gateway finish，运行时效果写入既有ConversationGenerationRound（origin=writer.runtime）而非伪造native调用；renderRequired为可修正业务前置错误，提交不确定/清理错误立即失败。终止前吸收补充，并在实际提交期间明确拒绝迟到补充，避免已接纳输入被忽略。普通进度原始signal以control事实持久保存，不先占回复FIFO；真正回复时生成独立摘要输入身份并预留容量，持久化失败关闭对应历史，防止busy残留。轮次元数据位于已有中立producerMetadata，轻量分页读取小型metadata及预览、不展开源码chunk；无SQL schema更改或数据库清空。

轻量查询验证补充：现有Storage只为generating响应保留身份，phase/path等内容到完成才落盘。为实现“请求开始即能查询”，携带中立producerMetadata的请求在开始边界显式保存generating状态与请求元数据，Writer调用模型前checkpoint；源码delta仍仅在内存累积，不引入每token SQLite写入。无producerMetadata的既有调用不改变持久边界。测试直接查询生成中的轻量记录，不能仅在请求结束后断言。

原生验收补充：当前宿主没有Simulator.app且CUA无法控制Simulator，但simctl虚拟设备可用。新增scripts/Test下的独立XCTest UI验收入口，在临时构建目录创建runner，不改应用框架或添加仓库目录；安装已构建模拟器应用，使用本机合成测试SQLite种子，在真实Settings/Writer页面点击、截图并验证入口/头部/轮次。若XCTest设备服务不可用，记录明确失败和可执行入口，不以布局替身冒充实际点击。种子只写模拟器，不写真机数据库。

原生验收测试夹具从已结束的模型实验数据库通过 SQLite 只读连接 backup 生成一致快照（包括 WAL 已提交内容），不得仅复制 base 文件造成虚假的 interrupted 状态。测试只在独立模拟器中种子化。

全量回归发现轻量metadata查询必须区分当前协议合法的空预留身份和损坏JSON：空data无metadata，非空仍严格解析，不增加旧协议兼容。预览worker用例仅等待调度启动的测试期限改为20秒，避免千项并发测试时5秒线程池饥饿；750ms生产合并和取消/无重试断言不变。

补充普通进度合并并发围栏：在异步读取当前任务/状态之后、取走待汇报摘要之前再比较eventID；期间若已被新进度替换，重新读取最新项，不清除或播报旧项。补充空闲普通进度实际触发、十秒节流、用户输入优先及最新摘要回归。

持续预览与任务记录专项已实现：默认Writer预览worker、按实际请求记录/报告、自然终止共享发布、Assistant普通进度latest-value节流、独立记录入口及头部/轮次页面。双模型六流程各6/6通过，原始简短流程图分别4/11请求；原生模拟器页面/HTML/PDF/ZIP/任务分享实际点击通过。证据与模型等待限制见docs/validation/Writer-Continuous-Progress.md，完整检查和真机结果在该文档单列；真机语音/真实Writer交互仍需解锁后验收，不据构建或导入历史点击提前归档整个Writer需求。

## 回合完成汇报与跨Agent窗口可见性（2026-11-04）
修正请求开始即向Assistant汇报的行为：请求开始只更新Writer自己的任务岛和SQLite请求身份；一轮控制模型及该轮工具/内容生成结束、工具结果落地后，在进入下一轮前汇报实际完成步骤。内容生成属于该轮工作，失败恢复报告仍基于已经发生的失败，终态/追问沿原有正式输入，不重复普通汇报。请求次数统计仍是实际模型请求attempt。流式预览继续独立，回合边界加入已有最新预览，未改源码不重载，不强行运行未完整脚本，不重开最小化/关闭窗口。
WriterWorkflow增加回合完成端口与轻量预览加入端口；WriterAgent请求开始只控制本域Island，普通进度统一在回合边界生成，移除分散的工具/提交和开始生成通知。已有失败/终态/有限恢复不变。
WindowState已有唯一全窗口状态且与创建者无关，保留所有权；BasicSkill主动声明ui.windows，使默认Assistant能发现Writer/浏览/相机窗口。WebPageContainer在ui.web中增加按windowID的被动子页面摘要（content/title/远程URL/loading），隐藏本地路径，不创建/加载/执行页面。Web.Page.inspect/snapshot/navigate接受可选windowID，通过UI根现有session查询目标，省略时仍为根浏览页；不复制Writer作品状态、不获得文件编辑权限。对明确target不隐式重开窗口，失败明确，截图/读取仍是未可信观察。根浏览与目标窗口各自生命周期隔离，取消只作用于该次操作。
BasicSkill/Assistant指令与各Skill description讲清用途、何时加载及可见事实不等于截图：先利用当前全窗口State，缺读取/截图能力加载web-browsing，窗口控制加载application-control；不要因Skill未加载直接声称看不到窗口。Writing/浏览示例使用真实windowID，说明Writer窗口同样可读/可控；所有Assistant入口仍是调度XML Action。
涉及Writer、UI/Web、Actions/Web及装配、Resources/Skills/Assistant、测试和拥有者README。既有目录内实施，不改框架调度或State选择机制，不设模型输出/总轮数上限。验证回合完成先于下一模型请求、刷新后报告、无开始广播、全窗口/子页面被动状态与目标隔离、默认Skill加载后原生XML查询；运行完整check和iOS构建，分别记录自动化/模型/设备证据。

增加真实Assistant模型的两个受控场景：默认目录发现Writer窗口后按需加载web-browsing读取指定windowID、加载application-control最大化该窗口。使用现有qwen-workflows.json与生产Assistant/Gateway回归，设备/页面效果明确为替身，不伪装原生渲染；不在用户输入中指定应调用的Skill或函数。

多页面State汇总需适配现有每来源8KiB观察上限：最多4个session加根页面，标题最多128 UTF-8字节、公开URL最多256字节，超过的单字段为unknown，完整URL/正文仍由显式Action返回，不丢窗口ID。修正旧真实模型回归夹具缺失agents.writer来源的问题；生产已有公开resolver不受影响，首次受控运行在模型调用前missing，需保留失败证据并重跑。

回合边界进一步明确为每次模型生成的完成步骤：控制响应要求独立内容请求时，成功建立编辑范围后先汇报“已准备编辑”（不能声称文件完成），再进入内容模型；内容提交并记录工具结果后汇报“已更新文件”。普通控制轮在工具结果落地后汇报。同一请求身份只汇报一次，多文件内容请求分别完成分别汇报；最后一轮由终态汇报。取消时不发送迟到普通完成消息。

完整回归发现三处接入问题：新增windowID参数须显式required=false以保留根浏览用法；默认窗口State导致两项旧选择集合断言需要按当前声明更新；新增教学过长超出现有提示/Skill共存预算。压缩发现文案与重复介绍以维持原预算，不扩大限制，不删关键能力；重新验证所有示例和三Skill共存，再复测真实模型。

针对用户再次反馈慢，使用既有Writer真实模型回归增加仅评估的thinking开关（默认enabled保持原实验），以原始简单流程图goal进行Qwen minimum对照。生产Writer的模型/用户thinking配置不改，不增加输出或总轮数限制；报告首事件/首次有效预览/总耗时，区分回合机制与推理模式。

新增共享读取的并行边界：Writer刷新与Assistant截图/JS读取共享页面时，导航更新应抢先取消旧读取，不让原生查询槽busy导致Writer渲染失败。规则归UI WebPageContainer，对所有导航一致，不识别Writer角色；旧读取显式CancellationError/迟到回调围栏，零排队不变。原生测试以有界慢DOM getter制造在途读取，验证新页面加载成功和旧读取取消。

同一场景集的历史页面断言同步到现行assistantHistory导航目标，保留原用户输入与稳定场景ID；旧实验结果不重写。

## Writer默认低思考与可选开启（用户确认）
用户选择默认关闭/最低思考、优先响应。现有ProviderSettings/CloudSettingsDraft增加writerThinking布尔值，默认false；设置页Writer云模型区增加“深度思考”开关并沿既有保存/恢复/回滚事务传递。配置文档中它是可选覆盖值，缺省表示当前角色默认false，不增加旧版本分支或迁移，不清空SQLite。Writer新委托获取模型租约时读取此选择，false采用现有OpenAI minimum策略（可关闭则关闭），true采用enabled；Assistant保持minimum。新委托/续作生效，当前执行及其已持有/恢复租约保持原配置。UI基础模块只保存布尔草稿，不导入模型枚举；业务装配选择Provider策略。
涉及Actions Provider合同/持久化/表单适配、ActionsBusinessAssembly模型租约、UI Settings值/状态/表单/视图及已有测试/README。验证默认false、开启往返、保存失败回滚、草稿revision/还原、角色配置隔离；重新运行check及iOS构建。已有模型minimum实测证据复用，不加输出上限，不修改Provider/模型选择或凭据。

回合/窗口/低思考专项交付：最新check与iOS四目标构建exit0；真实Qwen默认Skill发现2/2、minimum简单图1/1、原生共享页面导航抢占/状态/截图以及设置持久/回滚通过。默认低思考和显式开关已实现，现存执行保持租约。完整证据与本轮未安装真机的边界在docs/validation/Writer-Round-Window-Visibility.md，不提前归档整个Writer需求。

## Task Action统一入口（2026-11-04）
按用户要求移除重复的delegateTask模型入口及绑定，不保留别名。BasicSkill仍集中暴露调度的XML Task Actions。startTask(goal,execution?,executor?,skills?,taskID?,replaceCurrent?,title?,entry?,businessContract?,payload?)：execution默认foreground，由当前Agent处理，只有goal/skills/execution合法；background必须给executor，表示不能直接与用户对话的后台执行者。当前创作执行者writer使用可信writer.author契约，运行时附原始输入；taskID续作、replaceCurrent取消加入、title/entry仅属于Writer，不允许模型为Writer指定业务协议/目录/Skills。其他已注册后台契约保留既有businessContract/payload和Skills验证机制，用于受信宿主/未来Agent或进程适配端点；不增加进程执行器、不扩大现有授权。
startTask后台分支不创建或结束Assistant前台Task，不更改其Skill目录；只等待接纳，保持Writer独立loop/窗口/上下文。前台startTask仍独占一次XML响应以等待目录提交；后台也使用单Action响应等待接纳，但无需先开前台Task或加载writing。Writer事件不能自动发起新任务；同一用户输入最多尝试一次Writer后台启动，busy/替代/续作围栏保持。
cancelTask(reason,taskID?)省略ID只取消当前前台Task；带实际后台ID则请求执行者清理，接纳不等于已取消，终态仍由执行者确认。finishTask只关闭当前前台Task，不能宣告后台成功。sendMessage(taskID,text,interactionID?)仅补充后台输入，取消统一走cancelTask，不再使用type参数。后台通信继续由Gateway既有TaskSignal/所有权校验传输，不修改框架级调度。当前交互输入仍限制为Writer契约。
涉及Actions/System/Task定义及目录绑定、Agents/Support/Chat分流/取消、Basic/Writing/Assistant提示及示例、模型回归场景和测试；实现后同步这些拥有者README、Agents整体和跨模块说明，保留旧验证报告原样。验证前台/后台共存、默认入口无delegateTask、Writer新建/续作/替代和异常拒绝、后台取消/原生模型隔离、过期交互、通知不递归启动及旧参数拒绝。执行check和iOS构建，不清空真机数据库，不自动覆盖设备正在运行的任务。

Task Action统一入口已实现：生产注册/提示/当前README不再包含delegateTask；startTask前后台分流、executor、cancelTask后台ID和输入专用sendMessage落地。完整check及iOS四目标构建exit0；38个委托/FIFO用例、取消证据和提示预算通过。历史验证资料保留；本轮未安装真机或运行真实Provider，详见docs/validation/Task-Action-Unification.md。

## 后续独立专项：记忆与记录统一管理

Writing Skill 的命名、作品管理归属和重复教学调整留到[统一记录与记忆管理](Unified-Memory-Plan.md)专项。该专项将 Writer 任务记录、聊天记录和综合记忆纳入 MemorySkill，并评估独立记忆 Agent；目前仅登记，History 与 Writing Skill 均暂不修改，不增加当前 Writer 交付范围。

## Agent 自有灵动岛终态撤下（2026-11-04）

按用户修正：Writer 清理及任务终态持久化完成后，发布自己的 UI.Island.end，不保留成功／失败／取消／中断活动；不调用 Assistant 的前台 startTask/finishTask，不关闭作品窗口或其他生产者活动。等待输入、暂停、取消清理期间保留活动，迟到的同 run 非终态与旧 run 消息不能重新显示。失败详情继续由 SQLite 和独立通知负责。

Agents/Support 的共享发布机制维护稳定 owner/session、递增 revision、一个在途加一个最新待发内容，支持 present/end、可观察失败及停止加入。Writer 仅维护业务阶段；AssistantExecutionSession 根据现有 AgentRuntime 的 Skill 状态订阅发布自己前台任务的活动，通过已注册 Gateway 内部展示工具执行，不增加模型工具、不改变 Assistant XML 调度协议。删除 Actions 从任务日志推导 Task 岛的重复生产者。相机、蓝牙和实际语音播放仍由 Actions 的能力拥有者投影，不移入不拥有这些状态的 Agent。UI 继续统一布局、动画和优先级。

涉及 WriterIslandPresentation/WriterAgent、Support/IndependentOutputWorkflow、Assistant/AssistantExecutionSession/AssistantProcessing、AgentRuntime、Actions/UI/Runtime/IslandDomainPresentation 和相关 README。复用现有目录与注册，不增加框架调度器。测试各类终态撤下、迟到更新、替换 run、失败重投、停止清理、其他活动保持及 Assistant 前台生命周期；运行 check.sh、build-ios.sh，自动化与真机验收分开记录。

实现细化：合并队列可能在首次 present 前只留下 end，系统提交失败也可能发生在本地已撤下之后。UI.Island.end 因而需要同 owner/revision 的幂等结束，并在未显示过的活动上保留现有有界 ledger 中的结束围栏，防止迟到旧 present 复活；不改变 remove 的严格编辑契约。权限、根 generation、正 revision、ledger 容量与跨 owner 拒绝不放宽。相关 UI 契约和回归同步维护。

本节代码与技术 README 已同步：共用发布器、Writer 终态结束／迟到围栏、Assistant 自有前台任务展示、日志旁路移除及 UI end 幂等均已落地。完整自动化通过；构建与真机验收边界统一记录在 [Writer 验证](../validation/Writer-Agent.md#2026-11-04-agent-自有任务岛结束)，不将构建等同于设备体验验收。

## 2026-11-05 无感流式预览与视口保持

真机反馈：生成／编辑HTML时反复黑闪、手势被打断，无法向下阅读。根因是ArtifactPresentation每次切换双缓冲目录，并把该目录作为WebKit读取根；UI prepare判定根变化后close/recreate WKWebView，随后整页导航又重置文档与滚动／缩放。

实施：Artifacts保留每项目两个可清理快照槽，每槽使用唯一版本子路径避免本地资源缓存串版；读取根固定为该项目预览根，不扩大到别的项目。UI增加受控本地preview更新能力：首帧或由完整脚本页切入时建立禁用内容脚本的文档，后续在同一WKWebView／document内执行宿主隔离content world的DOM差异更新。保留可复用元素（优先id/data-key）、不重建根body，不逐次导航；版本／代际／取消围栏阻止迟到更新。脚本、事件属性、活动嵌入及refresh不进入增量预览，完整脚本仍只在显式完整渲染运行。样式先在不生效状态准备，准备完成再同步提交，避免短暂裸页；资源加载失败明确上报且保留旧画面。

视口在实际DOM提交前采样；保留视口内可复用元素的相对位置，元素缺失时保留可用滚动坐标并依法钳制。用户正在拖动／缩放／惯性滚动时不强行scrollTo，不接管触控。复用WebView自然保留缩放。完整本地重新渲染保留同一原生视图、相对缩放与滚动位置；iOS以旧画面快照作为短过渡遮罩，直到新页布局与视口恢复，遮罩不接管触摸。真正更换远程／本地安全域仍走原有隔离，关闭／不可用释放过渡与待处理工作。

修改范围：Actions/Artifacts/ArtifactPresentation及README、UI/Components/Web的原生实现与README、既有WebKit/Artifacts测试和模拟器验收入口、模块及整体设计。使用既有目录，不新增依赖／框架调度器，不改变Writer模型循环或源码输出限制。一个原生变更在途、零排队；沿用查询／截图取消优先级、10秒原生操作和25秒导航期限。样式准备、取消及旧版本有界清理，不保留无界快照或observer。

验证真实WebKit文档／原生view身份持续不变、按内容局部更新、样式与相对资源刷新、脚本禁用及显式运行、滚动／锚点／缩放、交互期间不抢位置、完整render视口恢复、取消／根关闭／观察并发；运行check.sh与build-ios.sh及现有模拟器WebKit验收，真机交互结果独立记录。前一字幕任务的未提交修改保留。

验证细化：真实 WebKit 发现删除最初 document URL 所在快照后，后续文件子资源会失去有效加载来源。因此在同一项目预览根保留一个稳定宿主 HTML 文件；双槽仍只保存两个资源版本，宿主 DOM 通过受信 base 指向当前版本。UI 增量接口单独接受资源入口，不把资源基址与 document 身份混用。iOS 完整导航结束时原生缩放边界可能尚未更新，视口恢复需在有界布局等待后执行，不能在临时 maxZoom=1 时误钳制用户缩放。

本节实现已完成并同步 Artifacts/Web、UI及整体技术契约：稳定宿主与双槽资源、同文档 DOM 更新、样式准备与失败保留、视口/缩放恢复和完整运行过渡均已落地。check.sh、四个iOS构建及定向WebKit/模拟器验证已执行；既有Metal原生套件日志缺口、未进行真实模型和真机手势验收的边界见 [连续预览验证](../validation/Writer-Continuous-Progress.md#2026-11-05-连续-html-预览与视口回归)。不将自动化文档连续性等同每帧无闪的物理验收。

## 2026-11-05 Writer 记录排版与耗时

任务列表目标最多两行尾部省略；下一行左侧依次任务ID、累计轮数、最新状态标签，右侧更新时间。详情头部依次目标/ID、开始时间、累计持续时间、执行轮次、最新状态，目录/导出保留位置；请求行去图标与“第X轮”等冗余，改用简单编号，保留阶段/文件/时间/结果证据及run分隔。

Writer通过既有ChatTiming采集Provider首个公开token延迟，不把接收事件时间伪装为TTFT。Storage现有请求证据增加可选完成时间，沿原SQLite证据链保存；没有真实采样时明确未知。请求详情展示首token耗时和总耗时，文件内容响应默认折叠，工具参数/结果也可折叠，正文不截断。总耗时从实际模型开始（若无Provider采样则本次请求接纳时间）到记录完成，失败/取消保留已知计时。

Task仓库现有run查询暴露已有finished_at；Writer投影每次run耗时并累加，运行中用当前时间延续，续作间隔不算执行耗时，不扫描全文请求。UI仅消费通用显示值，不读Storage或ModelKit。涉及UI/Settings、Agents/Writer、Storage Chat/Tasks/SQLite及其技术README；不新增目录、数据库表或模型输出限制。验证SQLite重开、计时和累计耗时、折叠排版；运行check.sh与build-ios.sh，模拟器/真实模型/真机证据独立记录。

本节实现与技术README已同步；完成SQLite重开、Provider采样链路替身、跨run累计/未知耗时、12种Writer流程、模拟器实际点击/源码折叠及四目标构建。完整脚本与末尾定向回归均执行，原生Metal日志缺口和首次UI测试标识失败单独保留。证据及真机/真实模型边界见[Writer验证](../validation/Writer-Agent.md#2026-11-05-writer-记录布局与计时)。

## 2026-11-05 作品标题、副标题与后台连续执行

窗口标题由Writer创作域维护简洁作品名，避免统一“作品”。新项目先用委托title或goal派生的短名立即开窗，首个edit可同调用携带语义title，不新增命名模型请求；续作默认保留已持久标题，仅明确改名或新作品时调整。提供rename用于明确改名；重名仅在窗口显示层加稳定区分后缀，不改作品索引标题。灰色Web栏消费通用窗口subtitle：先为原始目标，后为真实模型/文件/渲染步骤、等待和终态，禁止使用源码或思维内容。Writer经Gateway direct的Artifacts describe更新，Action内部直调UI；不经Assistant代管。WindowState拥有通用可更新title/subtitle和被动投影，UI不理解Writer业务。

普通scene变化只通知Writer预览可见性，不调用pause/resume创作生命周期；Assistant现有后台连续路径保持。真正根暂停/关闭仍加入工作清理。WriterPreview在场景隐藏时取消并加入自身预览worker，保留最新刷新意图；回前台重新启用，不把最小化/关闭与后台混同。Artifacts保留每项目最新快照，后台不新建窗口、不执行WebKit，返回deferred证据；源码和发布可继续，不能宣称完成视觉验证。回前台由Artifacts恢复已有窗口/后台首次作品的最新画面；显式关闭/最小化不被恢复逻辑重开。渲染期间切后台和截图竞争也降为真实deferred/nil，不能让Writer因不可见页面失败。新建窗口等待回执时切后台，不把仍保留的窗口误标为用户关闭。

更新范围：Agents根/Writer/预览与指令，Actions Artifacts/装配生命周期，UI Window/Web/Root通用呈现及对应README/整体设计；不新增目录、框架调度器或ModelKit修改。明确iOS系统可挂起进程；此改动保证应用不因scene主动暂停Agent，不承诺无限后台CPU时间，不借用虚假音频保活。测试标题持久化/续作/重复名、副标题阶段与身份隔离、后台持续模型/文件处理、无渲染/安全发布、前台恢复与关闭/最小化尊重；执行check.sh/build-ios.sh，设备/真实模型验收分开记录。

窗口创建允许宿主预留通用windowID，Artifacts在等待呈现回执前绑定该身份；切后台中断回执时可准确保留所属窗口，不按标题或未绑定窗口猜测归属。回前台恢复仍只遍历最多四份自有快照，不能影响其他项目或Agent。

本节代码及技术README已对齐：角色Scene通知与显式暂停分离，运行中/首次呈现/最小化及取消边界均有回归；标题通过现有创作调用完善，副标题经Gateway direct提交。完整检查、收尾Writer回归和四目标iOS构建完成。先前iOS条件编译接线失败已修正并保留证据；真机/真实模型及iOS首页点击未执行，见[Writer验证](../validation/Writer-Agent.md#2026-11-05-作品窗口命名副标题和后台连续性)。

## 2026-11-05 请求轮次行：编号徽章与操作标题

请求行改为左侧垂直居中的彩色数字徽章，右侧两行：实际操作标题（可尾部省略）与时间/中文状态标签。写入/修改/读取/渲染/保存使用稳定语义配色，失败/取消状态优先强调；重试保留独立编号并在标题标记。run分隔和请求详情不改变。

标题由Writer根据当前原生工具名、参数中的目标文件及简短编辑指令派生，多操作有序去重组合；文件内容请求使用“编写 filename”，生成中或没有工具事实的轮次使用中性标题。不得从源码/工具结果/思维文本猜测，不额外调用LLM，不把接收工具调用等同执行成功。

Storage MessagePreview扩展中立的工具名/参数摘要，通过现有preview_metadata证据读取，无额外全文请求或逐行详情查询；不解析Writer命令，不新增表或兼容旧协议。WriterContainer负责业务标题/配色投影，UI仅消费标题、通用tint和已有状态。涉及Storage Chat/SQLite、Agents/Writer、UI/Settings与测试README，保持既有目录和模块边界。先回归多工具、重试、未知/失败/取消和SQLite重开，再运行check.sh、build-ios.sh及原生模拟器记录页验收；真实模型/真机另行记录。

本节实现及技术README已同步。标题取实际工具事实，编号徽章与双行布局、中文状态/重试、工具失败优先及原生滚动查找均完成验证；完整检查、四目标构建与模拟器验收结果见[Writer验证](../validation/Writer-Agent.md#2026-11-05-请求行彩色编号和操作标题)。UI首轮同名请求定位失败已保留并修正，未安装真机。

## 2026-11-05 Writer任务标题正文色

按真机反馈调整UI/Settings/WriterRecordsView：任务列表goal和详情头部goal使用系统primary正文色，紫色只应用Writer图标，避免整段目标染色。沿用既有截断/布局/编号徽章/状态标签，不改变数据或Agent逻辑。同步Settings技术README和验证记录；执行check.sh/build-ios.sh，不为纯颜色样式增加实现镜像测试。

本节颜色修正、技术README及验证记录已同步；完整检查、四目标构建和原生模拟器截图验收完成，未安装真机。证据见[Writer验证](../validation/Writer-Agent.md#2026-11-05-writer任务标题正文色)。

## 2026-11-05 请求数字徽标双色

按反馈将请求轮次数字徽标统一为默认灰色，仅failed显示红色；取消、中断、进行中及完成均使用默认灰色。保留操作标题、重试说明和状态标签。移除Writer到UI的操作配色枚举与参数，Writer仅投影标题和真实状态，UI负责两色呈现。涉及WriterContainer、WriterRecordsView及既有测试，更新相关技术README并运行check.sh/build-ios.sh，原生模拟器截图单独验收。

本节实现和技术README已对齐，四目标构建与原生模拟器记录页通过；完整检查的两项非Writer失败独立复跑通过，完整脚本仍记失败及原生套件日志缺口。证据见docs/validation/Writer-Agent.md的同日数字徽标双色记录。

## 2026-11-05 My Assistant / My Writer 列表视觉统一

采用同目录通用记录行：左侧20pt图标、24pt固定栏，与右侧整块文字居中；右侧17pt系统正文标题两行尾省略，6pt间隔后12pt灰色辅助行，行上下约12pt留白。Assistant图标蓝色、Writer柔和紫色；箭头保留原生导航灰色，分隔线对齐文字。Writer顶部用与Assistant一致的分区起始间距。页面名统一My Assistant/My Writer；Assistant分区、按钮及列表辅助说明英文，不翻译用户原文和完整请求证据。

真实数据口径：Assistant只显示已有turnCount（缺失才使用已知turns.count）和createdAt，明确为会话开始时间，不伪造最新活跃时间。Writer显示稳定taskID、任务累计requestCount（真实模型请求尝试数）、最新status/phase及updatedAt；不以已加载页大小当轮次。状态短标签Completed/Failed/Running/Waiting/Paused/Cancelled/Interrupted/Unknown，未知不可误标失败。完成绿色、失败红色、活动蓝色、取消/中断灰色。元信息与标题左对齐，日期靠右；今年MM/dd HH:mm，跨年yyyy/MM/dd HH:mm，采用当前日历时区，使用紧凑24小时显示。窄屏/大字体无法容纳时以第二辅助行保留全部字段，不挤掉状态或日期。无需增加数据库读取或模型请求。

修改UI/Settings现有Presentation/View/State与UI默认historyTitle；App Composition记录目的地名称同步。共用视觉组件及日期格式保持UI目录内，无新目录/模块，不动业务流程/存储。同步Settings、UI、Composition技术README；日期边界/状态事实自动化与原生列表导航截图验证，运行check.sh/build-ios.sh。真机安装另行请求执行。

本节实现与UI/Settings、UI根及Composition技术README已同步；检查脚本和四目标构建通过，Writer实际列表及Assistant空态导航模拟器验收完成。Assistant有记录行及大字体/窄屏截图的证据限制、原生通用套件日志缺口见docs/validation/Writer-Agent.md同日记录。

## 2026-11-05 task_28 工具参数与错误反馈修复

移除ModelKit Responses增量/完成解析、ChatRequest历史校验、Writer控制输出的4096字节参数硬限。参数不得通过ChatRequest累计文本预算或事件单项字节上限再次被拒；原生参数交给Provider实际上下文约束，文字上下文/身份/配对及队列事件数仍保留现有约束。StreamLimits增加显式无单事件字节上限选项，云端Chat及默认路由桥使用该策略并保持128项背压，其他能力默认不变。不得增加模型输出token上限。

Writer控制重试在新请求中追加结构化上次错误（分类、code、stage、details、实际副作用和修正建议），失败请求没有执行workspace工具，不伪造tool结果；成功后将这些反馈纳入后续loop。内容重试在abort并确认清理后携带实际原因，不能只说previous attempt failed。工具执行错误继续使用真实call_id的tool结果并补足结构化诊断。清理/提交不确定和取消保持不重放。最多3次恢复不变。

参考DeepSeek Harness agent.ts的session日志投影、请求失败钩子、原生工具调用/结果，再核对其工具执行错误路径。Writer运行中保留有界完整调用组，续作恢复最近控制请求选定上下文而非完整数据库历史；本次不承诺全量历史或实现新摘要Agent。恢复失败尝试时加入其真实诊断，避免续作再次盲重试。已有上下文选择预算不扩大到参数payload，Provider决定其真实token窗口。保持system/原始目标、最新结果和错误配对，不将failed request当作已执行操作。

涉及ModelKit Core/Management/Language LLM/OpenAI、Agents Writer及既有测试目录，不新增模块/目录/数据库结构，不清空真机数据。更新各拥有目录README及总体技术边界；验证大参数流（超过4KiB和64KiB）、历史往返、原生配对、错误反馈跨轮保留、内容重试、续作诊断、取消与恢复耗尽。执行check.sh/build-ios.sh，替身与真实模型证据分开。

补充链路核对：Actions通用validateInput另有每参数65536字节限制，会在Gateway direct之后再次拒绝大代码补丁；本次一并移除通用参数值字节限制，保留键/参数数量/声明类型及领域校验。更新Actions/Support/Contracts README及大参数验证。单次短意图、路径等领域语义约束不作为通用源码参数上限。DeepSeek tools/pipeline.ts的toolErrorResult将Error文本与isError写入原调用结果，证明工具失败应作为下一步上下文事实而不是仅通知UI。

补充持久化核对：ConversationHistory.recordToolCall也有4096字节参数拒绝，AgentCore的完整native ToolCallParser同样存在；一并取消并验证SQLite重开后参数完整、失败续作带诊断。保留现有存储整体容量/显式错误，不新增单参数或输出预算。

SQLite大参数回归发现preview只识别内联argumentsJSON，忽略当前codec的分块字符串；修正为只解包该调用的参数字段，不加载完整请求/源码上下文，保留真实操作标题与工具状态。更新SQLite README并以重开列表投影验证。

进一步移除单次requestJSON的512KiB历史写入拒绝，避免完整大参数在下一轮请求快照里再次触发隐性单参数上限；沿用现有整体历史内存容量与明确溢出，SQLite大参数测试跨过512KiB并记录下一次配对请求快照。

native解析器的CapabilityRegistry共享参数校验仍有每值4096字节，最后移除该通用值上限，保留参数集合/必填/枚举及别名权限校验；XML单tag限额不变。补充完整native解析及权限校验大参数回归。

本节已实施并同步受影响的ModelKit/Agents/Storage/Actions及整体技术README。全量检查、最终9项定向回归和四目标/收尾主应用构建证据见docs/validation/Writer-Agent.md；真实模型与task_28真机复测未执行，未清库。

## 2026-11-05 SQLite作品目录及源码/观察容量修正

移除StorageChat响应累积256KiB及工具结果64KiB、Writer观察12000字节的硬拒绝；模型上下文选择仍是独立策略，完整源码和实际结果不因这些单项字节数失败。通用Action/Tool完成值也取消64KiB硬拒绝，避免已完成效果在Gateway返回途中伪装失败。队列数量、沙盒、配对和整体内存生命周期约束不变。

作品不再使用ArtifactWorkspaceIndex全局JSON。StorageFiles公开中立WorkspaceRepository契约及版本/草稿/目录值，StorageSQLite在同一SQLite pool用workspaces、workspace_revisions、workspace_files关系表保存项目身份、版本、草稿和文件索引/内容；不把整个旧JSON塞进BLOB。目录摘要不读取源码，项目/版本按ID读取。草稿和版本元信息/文件行在事务提交；发布的不可变文件仍由StorageFiles写入项目版本目录供WebKit/导出。Actions先写版本文件再以CAS提交数据库，失败只清理本次版本；删除先置deleting，清理文件后删数据库行，失败保留待清理状态。Writer任务projectID仍可信逻辑绑定，不修改Agent调度。

现有StorageDatabase发布workspace端口，App/Actions依赖装配注入；不新建模块或目录，不依赖Actions/Agents进入基础层。删除旧索引类型、JSON读写与测试，没有旧索引导入/兼容回退。新增schema标识沿已有开发期规则重建旧数据库；本次不连接设备清库。测试改用当前SQLite后端，覆盖并发CAS、草稿/版本重开、跨项目超过旧8MiB、删除清理失败、超过256KiB源码、长观察/结果持久化和Gateway返回。更新所有相关README及验证记录，运行check.sh/build-ios.sh，真实模型/设备另记。

返回链路还包含InputGateway及AgentRoundCoordinator对完成值的64KiB拒绝，一并移除，保持身份、轮次、配对和失败报告校验；否则长结果会在离开Artifacts后被拒。技术README同步这些当前契约。

长观察完整保存/返回后，Writer仅在模型投影层按既有48KB上下文预算为本批工具结果生成显式首尾摘录（提示完整结果已持久化、可分页读取），防止成功操作因下一请求无法容纳而直接失败。摘录预算从固定目标/指令和当前响应及调用数推导，不引入新的单结果拒绝上限，不截断实际文件或工具执行证据。

边界检查要求SQLite后端只由AppStorage与IntegrationTests依赖；因此将涉及SQLite的作品持久化测试归入现有IntegrationTests目录，AppWorkflowTests保留纯编辑/UI行为，不扩大其后端依赖。StorageDatabase/StorageSQLite显式依赖StorageFiles的中立WorkspaceRepository契约，更新边界图白名单以反映该直接接口，保留禁止基础层依赖业务和后端泄漏的检查。

最终结果记录链路补充：Writer运行时收尾也通过recordGenerationRound保存实际返回值，原有262144字节拒绝会再次阻断长结果，因此取消这项单轮结果记录上限，并在大源码/结果SQLite回归中覆盖收尾证据保存。整体历史接纳容量不变。

全量回归发现两项旧测试仍断言已移除的字节拒绝：ActionsContainer的超长完成值、CapabilityRegistry对待丢弃未知参数的4KiB限制。更新为验证长完成值成功返回、未知参数正规化丢弃；状态Action的完成种类约束、XML原始tag限额及参数数量/键名校验继续覆盖。

## 2026-11-05 Writer任务详情头部紧凑布局

仅调整UI/Settings/WriterRecordsView.swift：将任务目标与独立ID行合并为一个水平头部，左侧紫色图标按整个文本块垂直居中，右侧上方使用caption灰色等宽taskID，下方完整显示goal并允许自然换行，不省略。保留任务信息、文件浏览和导出操作顺序。执行轮次徽标数字由body缩小为subheadline，沿用灰色／失败红色语义及原触控行。同步Settings技术README及验证记录，执行check.sh与build-ios.sh；不修改任务数据及业务接口。

## 2026-11-05 Agent所有权、可读任务与内部委托身份统一

用户授权重建开发SQLite，不保留旧ID协议兼容。前台任务由Assistant创建管理；后台任务由被委托Agent接纳时创建管理。外部业务主键为agent_id + task_id，task_N在Agent内原子递增、删除不复用。Assistant运行时生成UUID delegate_id，一次逻辑委托及其重投复用，续作生成新UUID；替换runID/run_id/DelegatedRun等旧名，通信scope明确关联delegate。Writer在接纳时通过Storage分配/恢复Task、独立对话和绑定，不再由Assistant预建Writer任务；Assistant仅保留委托及来源关联，Writer通过started/终态回复可信taskID。取消/补充从agent+task定位当前委托，interactionID由运行时解析，不向模型暴露UUID。

去除独立project_id；StorageFiles定义中立WorkspaceID(agent,taskID)及安全路径，WorkspaceRepository用复合身份及SQLite结构化列管理版本/草稿，物理目录为ArtifactWorkspaces/<agent>/task_N/<revision>/...。任务无永久完成语义，列表的执行状态是最新委托投影。Writer/Artifacts/UI业务值、文件浏览导出、恢复、预览、版本及窗口关联统一使用工作区身份，内部revision等UUID保留。

模型可见window_N由Window组件分配，内部UUID继续维护动画/异步回执，通过统一映射供Action/State使用，不暴露内部UUID。taskID、windowID携带标题/目标/阶段等owner投影，其他内部delegate/event/interaction/request/session/dialog/revision及因果链ID不作为模型填写参数。原生Provider tool_call_id按原协议保留；人可见请求轮次仅序号，不充当身份。持久dialog身份使用UUID，SQLite内部整数主键允许保留作连接键。

涉及Storage/Support、Files、Database/Tasks/Chat/SQLite，Agents/Writer与Support/Communication/Chat/Core及配置，Actions/Artifacts/System/Task/窗口，UI/Settings/Window，App装配与脚本/测试。保持编译依赖和现有模块目录，不引入新目录/调度器。先更新本计划，实施后协调各owner README和总体设计。验证Agent内编号隔离/不复用、委托幂等、目标Agent准入、续作同目录/新委托、来源会话删除、迟到事件/取消围栏、模型可见身份无UUID泄漏、SQLite重开、文件路径/导出/预览与窗口映射，运行check.sh与build-ios.sh。设备数据库仅在后续明确安装/操作时按schema规则重建。

历史查询本身也需要模型可操作的可读引用，因此对话保留dialog_N作为历史查询reference，另外在SQLite对话行记录独立UUID traceID用于内部溯源；整数连接键不作为UUID使用。二者是当前契约的两层身份，而非旧协议回退。其他内部请求／委托／事件／交互均使用原生或UUID身份，展示只使用轮次／委托序号。

文件编辑工具的读取引用、savepoint和版本选择也属于模型需要回填的句柄，一并改为read_N、savepoint_N、revision_N；内部流事务/持久版本仍使用UUID，由Artifacts在域内映射。避免只隐藏通信UUID、却让编辑工具继续要求模型抄写UUID。

命名收尾：ArtifactStreaming的会话键实际是一次委托的执行权限，参数统一命名delegateID，避免继续把UUID称作taskID。Artifacts仅在Gateway通用执行上下文边界读取taskID（其框架含义为scope），随即转换为域内delegateID；不改框架调度契约。持久作品taskID仍为Agent-local数字身份。相关原生调用与替身同步，不留旧参数兼容重载。

本节ID改造已实现，相关Storage/Agents/Actions/UI技术契约及提示词已同步；主检查与收尾定向回归证据见docs/validation/Writer-Agent.md的2026-11-05身份改造小节。设备及真实模型未验收，本轮未安装或操作设备数据。

## 2026-11-05 总体设计悬空内容归位（文档整理完成）

本次仅整理当前技术文档，不改变代码、运行时接口或模块边界，不新增目录。实施范围：

- `MobileHarness/README.md`：移除 Part III 之后悬空的 Web/Writer 增补；通用 Assistant 委托时序、认证、接纳与完成边界归入角色通信章节，网页/作品数据流、设置、历史、模型、字幕、Island 和场景生命周期分别归入既有主题。总体设计保留跨模块契约并链接细节拥有者。
- `MobileHarness/Agents/Assistant/README.md`：从 Web 观察章节拆出对其他 Agent 的委托契约，描述调用、运行时身份解析、结果消费与取消边界；明确通用传输机制与当前已接入 Writer 的产品能力不同。
- `MobileHarness/Agents/Writer/README.md`：集中 Writer 的创作流程图、主动事件/持久通知、Assistant 接收侧政策链接、模型/文件恢复、历史与呈现细节；合并重复段落并将尾部内容归入对应小节。
- `MobileHarness/Agents/README.md` 与 `MobileHarness/Actions/System/Task/README.md`：同步委托导航、所有权与当前公开参数，避免将运行时 UUID 或 Writer 专属行为写成所有执行者的通用能力。
- `docs/history/Documentation-History.md`：记录本次归位及验证范围；当前技术 README 不保存整理经过。

验证按当前源码核对委托/接收/取消与场景行为，检查变更文档相对路径、章节锚点、Mermaid 结构和差异格式。文档修改不运行代码构建，不据此声称模型、原生 UI 或真机验收。

归位与文档检查已完成，结果见[文档整理记录](../history/Documentation-History.md#2026-11-05--委托流程与总体设计尾部归位)。此项完成不改变本计划其他实施或独立验收事项的状态。
