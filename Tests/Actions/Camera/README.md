# Camera tests

## Capture enhancements

CameraEnhancementTests checks pure settings rejection, completion and error handling for configuration and preview unloading, monotonic countdown deadlines/cancellation, domain recording stop/join/audio-release/background behavior, idempotent collection and file-backed video ownership/retention/image isolation. Native recording callbacks and metadata in domain tests are explicit fixtures, not camera/microphone acceptance. PhotographerCameraTests routes all added UI operations through the actual role/Gateway/declared-Action chain. PromptTemplateTests covers loaded aliases, task cleanup ordering and the enlarged Photography catalog budget.

Recording handoff tests exercise the production VoiceRecordingAudioHandoff with an explicit suspended native-stop receipt: microphone sample stop retains ownership, recording admission waits for release, cancellation still joins, and cleanup failure rejects admission. Recording tests assert the actual window-derived angle reaches the native port. Native audio ownership and encoded file orientation still require device acceptance.








系统灵动岛验证覆盖活动容量/owner/revision/generation、原生提交合并/迟到状态/权限失败、阶段提醒去重与上限、后台暂停与根清理、导航白名单；Actions/Skill验证expanded请求与旧自定义几何拒绝、Task身份/中文状态/终态移除。自动化不证明系统动画或真机视觉效果。

灵动岛双呈现回归覆盖通用详情阶段/收起/结束、普通状态拒绝展开、相机优先整活动切换、后台只保留当前活动摘要、真实渲染回执围栏、频谱不重发摘要及系统失败下前台独立。布局检查左右同边距、硬件保护和有界标准圆角矩形；不替代真机动画验收。

Island集成校验新primary/secondary内容与Action解析、指定活动的展示偏好修改、任务自动详情以及系统权限失败与前台独立；图片端口只注册显示资源，不扩大BasicSkill。

VoiceTests的ASR失败回归覆盖创建失败及结束输入后的SFSpeechErrorDomain拒识替身：错误保留、字幕封口、Context及显示回到listening、empty轮次终态、下一句成功发布。此替身验证控制流，不等于Apple ASR真机识别验收。

VoiceTests还验证六次toggle与四来源共768条新revision空闲回执只产生六次聆听Action，迟到busy不能越过已更新围栏；多来源busy更新只在聚合进入/离开占用时各发一次暂停/恢复，替换incarnation的同态事实不重复执行。

ActionsContainer场景回归验证后台保留在途Action、已有准备票据及新请求接纳，原生场景关闭仍执行；完整invalidate继续拒绝新执行。

聆听计时覆盖elapsed编码/非法日期、固定高度与硬件对齐，以及连续聆听跨后台/领域更新保持起点、重新聆听重计。

灵动岛整理回归确认setPresentation目录只保留activityID/size，过时布局/动画请求在纯参数入口拒绝；业务域投影与通用执行保持分离，已有生命周期/优先级/计时回归继续适用。

PlatformSystemStatus测试验证驻留电量未知/充电/低电量字段、网络路径类型及离线语义、非法电量拒绝；不进行原生网络或电池采样。

Bundled Skill catalog validation includes web-browsing/web-drawing and their dependency expansion. The full behavior fixture explicitly supplies WebCapability alongside other optional host capabilities; it does not perform native browsing or generation.

状态覆盖回归从打包Catalog动态枚举全部Skill，逐个执行loadSkills→收集有效useStates→releaseSkills→再次收集。UI/Platform使用真实被动状态读取，iOS专属Actions业务节点与Agent应用摘要为明确替身；验证Web技能依赖、ui.web注册与释放，不调用模型或网络。

Web Skill教学回归逐字符解析实际Instructions.md中的XML示例，使用各Skill及依赖展开后的真实目录，验证别名/参数可接受、依赖调用分轮、创建与修改身份，以及完整已加载提示词的大小预算。它验证教学制品和执行协议一致，不代替真实模型遵循度测试。

Skill状态回归覆盖任意新路径无需Assistant登记、生产者完整Business嵌套、未知来源与有效来源混合采集、诊断固定原因码及关闭/取消/容量边界。旧字段白名单断言改为公开Business与内部Runtime的分类边界。


作品库仅由 Writer 原生工具拥有；回归覆盖 writing 加载失败、Assistant 不暴露作品库入口、仅查询时不创建工作区，以及打开/删除和错误目标；agents.writer 被纳入全部 Skill 状态读取测试的显式 Agent fixture。

WriterAgentTests 通过真实 AgentManager/通信与 Gateway DirectExecutionDispatcher 连接脚本模型和实际作品存储，验证后台接纳、流式编辑、发布与终态回报；呈现是明确 fixture。

Writer 分域回归检查作品库、编辑、只读呈现的 Skill 教学与 native 工具 schema，以及追问后编辑域恢复和无工具内容请求。追问测试核对回答文本进入后续模型请求。工作区回归检查 edit 回执的结构化事实及关联文件，配置回归检查 Writer 专属 Skill 的原生绑定与共享目录隔离。

Writer 续写生命周期回归使用真实 ArtifactService/SQLite、可控非协作呈现与检查点阻塞：跨 session、撤销后及恢复后的旧流被拒绝；取消的 complete 不接纳；变更竞争显式 busy，预览不阻塞追加；release/Actions 根关闭等待在途效果并拒绝迟到操作；已开始的 abort 不被撤销再次取消。文件系统失败夹具检查清理失败持续可见及关闭准入。测试区分工具接纳、文件写入和委托终态，不证明真实模型或原生 WebKit 行为。

Writer 工具集成回归使用真实 Artifacts 服务与呈现探针，验证默认不渲染、单次流式预览及最终刷新、关联文件上下文、搜索分页、目录移动/差异/草稿恢复、显式渲染后发布和运行错误阻止发布。它不替代真实模型或原生 WebKit 验收。

Writer 历史回归验证同一 SQLite 的角色隔离、重开后完整请求/工具结果/取消状态、图像引用的 Writer 输入所有权，以及真实 Gateway 后台创作同时提交 SQLite 历史、经 Gateway 归档。图片字节夹具只验证存储契约，不作为原生解码证据。

Writer 委托回归覆盖默认目录XML Action、保持已有前台 Task、主动事件触发模型、与用户输入 FIFO、重复消息去重、单任务竞争与错误 interactionID 拒收、完成证据满队列后同 ID 重送，以及模型获取前窗口呈现。呈现/模型仍为明确替身，真实 Gateway 与 SQLite 链路独立验证。

Assistant 协议回归检查所有内置 Skill 仅暴露 XML Action、BasicSkill 包含前后台任务控制、身份提示说明协作角色与委托范围；真实 Scheduler 驱动 XML 委托，生产绑定检查 Action scheduled/Tool direct，Writer 独立工具执行保持覆盖。

Writer 委托故障回归通过真实 Assistant XML、Gateway/Scheduler 和 SQLite 验证：模型在 failed 事件中尝试重委托被宿主拒绝；原用户输入内重复委托也不创建第二项任务，新用户输入仍可再次尝试。Writer 端点与模型使用替身，不代表真实模型或设备验收。

Writer失败回归覆盖先list成功后第二次模型请求timeout，实际Gateway记录modelTransport分类并向Assistant传送完整诊断；SQLite重开及通用UI DTO还原诊断，模型/阶段/输入ID/耗时和独立清理原因均保留。模型为替身，不代表真实Qwen请求成功。


Writer 自主任务回归覆盖接收端暂不可用时仍完成创作和发布、同事件重投、暂停恢复、Assistant 关闭后 Writer 继续执行、跨对话阶段汇报及共享 FIFO。语音回归使用受控识别与播放能力，验证连续转写、播放准入、恢复以及明确停止后的采集拒绝。

Writer independence regressions use real Gateway/SQLite with scripted models: rejected user notifications do not retain the creative slot, execution retirement supports successive delegations beyond the live-grant bound, and database reopen redelivers immutable events without another model lease or file creation. Assistant fixtures cover canonical-state reconciliation before new/resumed delegations and stale terminal messages after a new run.

Writer task-Island regressions use actual Gateway direct, Island Actions/UI state and SQLite with scripted model/rendering. A rejecting Assistant does not prevent start/file-step/terminal display; unavailable presentation retains only the latest task state, old-run callbacks are ignored, and root stop joins its publisher. Component tests cover semantic priority independent of producer names, speech/status coexistence, manual collapse and new-stage expansion. No model is asked to call Island tools. These are not native animation or real-provider acceptance.

Writer failure fixtures retain exhausted attempt counts and classified causes. SQLite reopen verifies the active failed native call and unexecuted siblings have paired outcomes. Assistant notification does not redelegate or rerun generation.

## 文件归属

- [CameraEnhancementTests.swift](CameraEnhancementTests.swift)
