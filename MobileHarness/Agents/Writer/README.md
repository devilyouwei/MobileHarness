# Writer — 私有流式创作工作流

WriterWorkflow 消费独立注入的 ModelKit.ChatCapability，要求原生工具支持。控制请求选择工具、短编辑意图或经过读取校验的短literal补丁；edit返回运行时流身份后，单独无工具请求输出原始文件内容，逐个增量等待宿主追加，避免源码 JSON/XML 转义和丢失。WriterTools 由宿主绑定身份和范围，模型不能创建授权。

控制历史按完整调用/结果组裁剪，保留本次目标及最新配对；不设置固定创作轮数或整任务期限；显式finish及正常无工具终止共用Gateway发布校验，成功后直接结束，不额外要求一轮模型调用。控制响应文本与源码流均不设额外字节截断，模型采用 Provider 默认输出预算；工具参数4KiB、观察12KiB属于宿主协议/上下文边界。取消会取消模型会话并中止写入；中止失败与原始错误同时保留。未正常结束的流不得完成事务。每个检查点读取追加要求，文件流期间不切换目标。

WriterAgent 是独立 AgentCore 角色，WriterContainer 随 Agents 根注册、暂停、恢复和关闭。来自 Assistant 的后台 writer.author 请求通过真实 Input/OutputGateway 认证；工作区工具直接返回，不进入 ChannelScheduler。单任务准入（等待补充、暂停和取消清理也占用），每任务通过 ModelKit ChatModel 获取固定模型配置的能力句柄，暂停/补充期间保留；SDK 统一管理并发/本地排队和资源回收，Writer 不关闭或重开模型租约。Writer 不复用 Assistant 的 ChatWorker、XML、提示词或对话历史。

Assistant 不参与创作循环或通过聆听/对话关闭终止 Writer；应用根拥有角色暂停/关闭，显式cancel在清理完成后确认。任务输入队列上限八项，满时拒绝；追加要求在文件检查点取出，写入恢复上下文。ask 工具发送带 interactionID 的 waitingUser 进度，结束当前推理并释放编辑租约；匹配输入后重新读取草稿继续。显式取消加入执行清理；前后台暂停保存未完成内容并中止请求，恢复重建工作区和私有上下文。窗口生命周期不决定任务生命周期。终态发送简短文本和artifactID，不携带源文件。模型与文件清理完成即释放创作占用，SQLite 原子保存执行终态和通知；通知接纳、回复或播报不影响下一次委托。

控制工具失败以有界观察反馈供下一轮修正；同一规范化参数的失败调用在草稿未改变时只执行一次，再次生成只返回原错误及修复建议，不重复执行效果。未推进草稿的恢复阶段最多接纳三次失败修正，耗尽才结束。成功编辑/移动/删除/恢复草稿后清除失败屏障，读取/查询不清除。可恢复请求进入 Writer 自有有限恢复；取消、提交不确定或清理失败立即终止。无效结束批次整体不执行并反馈修正；批次异常保留当前调用原始错误并为未执行兄弟调用补齐结果。完整配对后才添加截图或重复调用提醒。截图最多保留当前一张，不支持视觉的模型继续使用渲染文本和诊断。

## 编辑工作流与格式 Instruction

Writer 的 workspace 工具声明完整描述参数、失败修复和操作顺序。控制模型按需列出/查询文件、按行读取相关片段，用 contextReferences 将实际关联内容送入独立内容请求；新建/大段源码不进入工具参数，replace仅携带短精确旧/新文本。后续用户修订同时进入控制历史和内容请求目标。HTML/CSS/JS、Markdown、JSON、SVG 和纯文本的格式规则由 Writer 按目标扩展名选择，不加载动态 Skill。

WriterPreview拥有默认安全预览：源码追加或确定性修改只唤醒一个latest-value worker，经Gateway direct内部preview读取最新词法检查点，约750ms合并，一个在途加一个最新待呈现状态。页面重载不阻塞源码接收。相同快照跳过；窗口不可用停止该run的自动预览，不重开窗口。render/finalize/abort先取消并加入预览，根生命周期加入worker；run独立实例和加入屏障防止迟到帧。完整render执行脚本并提供诊断，截图缺失不宣称视觉验证。

工具支持目录前缀列举、按行/字符范围读取、带总数与继续位置的字面搜索、读取引用局部编辑、文件/目录移动与删除、savepoint/diff/restore、多版本列表及 restoreVersion。移动后模型负责修复链接/import。savepoint 是任务内有界多文件撤销点，发布仍由既有版本/CAS 完成。相关业务和存储规则见 [Artifacts](../../Actions/Artifacts/README.md)。

## SQLite 历史与设置页

WriterHistory 为每个真实控制/内容请求建立独立输入和模型请求记录，复用 StorageChat.ConversationHistoryStore 与 ConversationRecordStore(agent: writer)。生产装配使用与 Assistant 相同 SQLite Chat/Task repositories；无记录器仅用于显式测试实例，不是生产存储回退。完整文本/native pairs、工具定义、工具输出、用量、完成原因与失败/取消收尾保存到 SQLite。temperature 来自实际请求，控制与内容请求均不指定输出 token 上限，由 Provider 使用模型默认值；model 来自独立 ChatModel 的模型名称；不可用时明确标记名称未知。流增量先按既有 Chat 契约累积，结束边界提交；中断按现有 SQLite 恢复语义标记 interrupted，不重放操作。

委托 Task ID 与项目目标保留在 decisionMetadata/请求上下文，不加入 Assistant 的 Task message-source 集合。Writer 任务保持独立输入/请求身份，复用有界历史仓库写门。工具结果在独立内容请求结束后更新原控制记录，并显式 checkpoint。SQLite 保存失败会终止本次请求并保留原始/清理错误，不能报告虚构持久化成功。

模型输入截图复用既有 CapturedPhotoStore：SQLite 媒体记录和 StorageFiles 字节、请求中的 imageReferences、按 source=writer/input 校验的历史图片读取；沿用既有媒体容量与回收策略。模型请求 JSON 不保存 provider 凭据或重复 base64。

WriterContainer 通过 UI 自有 WriterRecordsControlling 提供分页任务、请求详情、图片及完整记录分享；App 只组合接口。没有手动新建会话、删除归档或标题生成的 Writer 管理通道。源文件预览和导出仍由 Actions.Artifacts 拥有。


## 委托与主动事件

Assistant 的 BasicSkill 通过调度的 XML startTask(execution=background,executor=writer) 发送目标与实际用户输入，Writer 先经工作区 start 工具显示窗口，再获取模型。agents.writer 公开 idle/starting/running/waitingUser/cancelling/paused、taskID、goal、step、interactionID。已有窗口不等于运行任务；单任务忙碌明确拒绝。sendMessage 的待答 interactionID 必须匹配；cancelTask(taskID,reason) 转换为可信 cancel 信号并立即接纳，由根拥有的 worker 加入清理并回报。

AgentTaskContent.writerEvent 携带版本1、UUID eventID、递增 sequence、started/progress/userInput/completed/failed/cancelled 与可选项目/窗口身份。工作区就绪、文件提交和实际渲染/修改步骤回报事实，不生成虚假进度比例。运行阶段由内存 reportWorker 投递 task.progress，每种事件最多保留一项待送达事实及一个不可变在途事件；新的同类阶段替换未发送旧阶段，任务结束移除过期步骤。实际接纳由 CommunicationReceipt 决定，拒收每500ms重试，不终止创作。

WriterNotifications 拥有独立于创作的持久终态投递。TaskRepository 将执行终态与不可变通知原子提交，通知保留原 eventID、taskID/runID 和认证 scope。两个 worker 分别投递 task.result 和 writer.completion：前者只退休 Gateway 执行权限，不进入 Assistant 回复队列；后者是普通认证角色消息，不使用已退休的 taskScope。每个 worker 分页读取最多32条通知并轮转重试，用户通知拒收不能阻塞退休或创作准入。失败证据与接纳/退休确认分别保存，通知积压不形成创作次数限制。

暂停/关闭加入创作和投递 worker，未送达终态留在同一 SQLite；恢复或新进程只重投通知，不重跑创作，也不重建旧执行权限。跨进程退休遇到已关闭 scope 时保留证据并结束退休分支，用户通知继续独立递送。Assistant 使用可信 SQLite 执行状态对账 busy、替代和发送消息；对用户的通知不是任务释放条件。

控制提示词明确 Assistant 是委托者和用户沟通者，ask/finish 由宿主发送回报；Writer 不生成 XML 调度或自行拼接跨 Agent 消息。独立内容请求只处理格式与文件编写，不承担角色协调。

## 长期任务与执行

StorageTasks 的 DelegatedTaskRecord 对应长期 taskID、Writer 对话、原始 goal 和受控项目目录；每次委托创建新的 Task 执行行作为 runID。scope.id 使用 runID；业务 taskID 不复用已关闭的通信身份。新建与续作在 Storage 单次事务切换 Writer 当前对话；续作复用原对话、项目及历史。Writer 校验可信请求与最新运行记录，工作区 start 的项目身份在模型获取前持久绑定。任务失败、取消或完成独立于回报递送保存；异常不会成为成功。

WriterHistory 从本任务最新控制请求恢复原生文本/调用/结果上下文，移除旧 system 指令，保留完整工具配对并按组裁剪，再追加本次目标；完整记录不随模型上下文裁剪删除。decisionMetadata 同时保存 taskID、runID 和实际请求阶段。WriterTaskEvent 携带两种身份，Assistant 核对 runID 与 envelope，旧执行不能复用新执行的通信权限。

Assistant 的后台 startTask(taskID?,replaceCurrent?,executor=writer) 控制新建、续作和强制替代。替代仅接纳一项在途控制，发送取消后最多等待25秒确认；清理失败或超时拒绝启动目标任务。Writer 保持单任务准入，等待输入、暂停和取消清理也占用。推理请求与文件操作清理完成后才报告取消；清理错误报告失败。新建总是使用新项目；旧项目只能从可信任务绑定读取，Assistant 不再提交任意 projectID。只读取当前委托任务及原生请求格式，不归组、导入或展示旧版历史。

Writer 在 start 前持久绑定预留项目，完成窗口准备后确认 workspaceReady。初始化失败的续作显式使用原预留身份建立工作区；已就绪项目丢失则失败，不创建替代目录。模型主动 CancellationError 属于失败，根停止属于 interrupted；只有 Assistant 请求且清理完成才是 cancelled。

## 失败诊断

WriterDiagnostics.swift 分类模型网络、HTTP、响应协议、模型配置、工具、存储、工作流、取消和清理错误。每次控制/内容请求保留阶段、模型、输入ID、尝试次数和单调耗时；WriterDiagnosticCapture保存最新未恢复请求失败，成功请求清除过期原因，不拥有重试。工具失败附实际命令/路径并区分读取、编辑、渲染和发布。清理失败独立保留原始原因及清理原因，不覆盖主错误。

通信使用 WriterFailureDiagnostic；Writer目录显式投影为 StorageChat.ConversationFailureDiagnostic，存入请求/工具 evidence，另将分类摘要保存到任务 failure。失败经 Gateway control 输出 AgentFailureDiagnostic，同时通过 WriterTaskEvent.failure 传给 Assistant。首页显示简短摘要，请求历史展示结构化分类/阶段/字段；无法从过去仅有 transport 字符串的记录反推已丢失的 URLError。

## 自有任务岛

WriterIslandPresentation 根据 Writer 自身生命周期发布开始、真实步骤、等待补充、暂停恢复和取消清理。通过角色内部 UI.Island.present/end 工具经 Gateway direct 执行，不进入 ChannelScheduler，也不加入模型工具定义，不调用 Assistant 前台 startTask/finishTask。清理及终态持久化完成后撤下自己的活动；持久化收尾失败也结束展示，错误证据保留在任务记录、诊断和独立通知中。关闭活动不会关闭作品窗口，不影响语音或其他生产者。

独立呈现 session、稳定活动 UUID 和递增 revision 与 Assistant 会话及执行权限分离；同一根后续任务复用活动，新 run/等待改变 expansionID。旧 run 和终态后的迟到进度被域内围栏拒绝，通知重投不会重放呈现。发布机制复用 [AgentIslandPublication](../Support/README.md)，只有一个在途和一个最新待发命令，结束命令参与同一 revision 围栏。失败通过 presentationFailure 公开，暂不可用每500ms重试最新事实，不影响创作、SQLite终态、新委托或 Assistant 通知。根停止先取消并加入 worker，再通过仍有效的权限尝试撤下并加入最后一次 end；失败保留证据，不启动无限清理重试。Scene 暂停保留域内容，由 UI 决定本地隐藏和系统摘要。

Writer 只构造简短目标/步骤、紫色图标、语义优先级和详情阶段；显示投影不会截断模型输出或持久历史。动画、几何、优先级仲裁、手动收起及语音顶部并存由通用 Island 组件统一拥有。Assistant/Task 日志不参与此链路。

## Bounded recovery

WriterRecovery permits at most three attempts for a model request, with cancellable500ms/1000ms backoff. Transient transport/HTTP and recoverable response failures retry; authentication/configuration, TLS, cancellation, storage and cleanup failures do not blindly retry. Natural terminal responses enter the shared publication check; missing publication prerequisites receive runtime correction; failed tools and invalid batches have a bounded correction episode. Repeated successful calls receive advisory context at3/5/8 repetitions without imposing a total creative-step budget.

Failed content generation joins abort before a fresh stream starts; no prefix is appended twice. Uncertain commit and abort failure stop without replay, preserving original and cleanup causes. Every actual attempt and paired tool outcome remains in SQLite. WriterRecoveryFailure retains phase, attempt count and last classified cause. Writer publishes recovery progress itself; Assistant never redelegates to implement retries.

## Raw source and bounded correction

Code-format content streams (HTML/CSS/JS/JSON/SVG) validate the initial prefix across deltas. An outer Markdown code fence fails with writer.content.markdownWrapper before commit; abort joins, a fresh stream is allocated, and the existing bounded retry includes explicit raw-source feedback. Markdown and text keep legitimate fences. This checks source packaging, not language validity; WebKit render remains the execution check.

Workspace parameters carry local descriptions and command enums (internal preview is not model-exposed). Character ranges are decimal offsets inside a fresh read reference; omitting offsets replaces that read range. Pre-dispatch invalidParameters becomes a repairable WriterToolFailure with validationCode and executed=false; undeclared fields are rejected rather than ignored. The common capability registry and Gateway remain unchanged. Instructions require the smallest goal-complete artifact and finish after successful checks, without unsolicited cosmetic rewriting.

`replace(path,reference,oldText,newText)` 校验当前文件读取引用、版本与范围，并要求oldText在范围内唯一匹配；失败不改草稿，空newText删除匹配。所有范围外字节保持原样，文件修改使原引用失效。此短补丁直接经Gateway执行，不启动第二次内容请求；成功后需要重新render。新建和大段改写继续使用edit源码流，不扩展原生参数边界。

## 请求可见性与快速收尾

每个实际模型attempt在SQLite建立身份和producerMetadata后，调用模型前只更新Writer自己的任务岛，包含inputID、跨run累计number、phase、attempt和path。普通汇报对应已经结束的模型生成及其实际步骤：控制请求成功准备编辑后汇报准备结果，再进入独立内容模型；内容提交及父工具结果持久化后汇报文件修改；普通控制轮在工具结果后汇报。进入下一模型请求前先加入已安排的最新预览，未改源码不额外重载。请求ID去重，同一请求不会因多个工具重复汇报；最终请求用终态，取消不发送迟到普通消息。首画面与失败恢复仍报告实际事实，追问独立投递。收尾前处理已接纳补充，运行时finalize保存在ConversationGenerationRound，来源writer.runtime，与provider tool pairs分开。

指令要求最小满足目标、尽早产生可见主体，不添加未请求动画/图纸信息，不反复读取刚生成文件；窗口不可见记录验证受限并收尾。Provider输出默认值及现有有限恢复不变。WriterContainer提供轻量WriterRequestItem分页，完整内容按消息ID按需读取；任务摘要以受控对话创建时间和中立timelineCount查询计算总轮次，不以已加载页数计数。

每次实际模型生成对应一次完成步骤：控制响应成功建立编辑范围后，可汇报“已准备编辑”再进入独立内容模型；内容提交及父工具结果持久化后汇报“已更新文件”。同一请求ID去重，普通控制轮在工具效果后汇报，最后一轮使用终态。请求累计计数不等于已经完成的文件数；取消围栏拒绝迟到普通步骤。

云端Writer新委托/续作模型选择默认关闭或最低思考；设置页可显式开启。模型选择与思考策略在句柄取得时确定，当前执行及其恢复沿用原快照，不因表单编辑重启创作。

控制/内容请求统一经 InferenceSession.withCleanup 消费，解析、写入异常及取消均加入该请求原生清理；任务终态保留清理屏障。固定 ChatModel 跨暂停和补充保持选择，资源卸载与本地排队归 SDK。
