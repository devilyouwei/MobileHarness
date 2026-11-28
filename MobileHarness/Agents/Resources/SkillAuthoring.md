# Skill 配置与撰写规范

Each Skill has one structured Skill.json. Description.md is the public discovery text. Instructions.md teaches the loaded workflow. Both have a Simplified Chinese sibling. In both languages, use the registered aliases, parameter names, result fields and ordering for the same operation. Assistant controls belong to Assistant. Writer uses its native tools.

每个 Skill 使用一份结构化 Skill.json。Description.md 供加载前发现能力，Instructions.md 在加载后教授流程。两者分别提供简体中文版，两个语言版本使用相同的注册别名、参数、结果字段和调用顺序。Assistant 自己声明 control；Writer 使用原生工具。

## 职责与边界

每个 Skill 目录是完整的运行时加载单元。`Description.md` 提供公开简介，`Skill.json` 注册可用函数及依赖，`Instructions.md` 教学业务流程、规则和注意事项。本层维护加载与资源 Schema。

Skill 是可复用的流程与能力集合，Task 是运行时目标、状态和上下文的拥有者。一个 Task 可组合多个 Skill，同一 Skill 可服务不同目标。Skill 不包含 Swift、可执行脚本、Action 实现、凭据或用户数据；[Actions](../../Actions/README.md) 独立实现函数，[Agent 配置](AgentAuthoring.md) 声明身份、通信和基础 Skill。

## 文件与索引

| 文件 | 作用与要求 |
| --- | --- |
| `../Catalog.json` | `version: 1`，`skills` 显式映射 Skill ID 到 `Skills/<SkillName>/Skill.json`。运行时按 ID 加载，不扫描文件夹。 |
| `<SkillName>/Skill.json` | 必需。v4 资源配置，引用 canonical 函数绑定。 |
| `<SkillName>/Description.md`、`Description.zh-Hans.md` | 英文与简体中文公开简介，供加载前的能力发现使用。 |
| `<SkillName>/Instructions.md` | 必需。UTF-8 静态运行时指令，与 Skill.json 同目录；加载后进入模型上下文。开发 README 不能替代它。 |

目录用 UpperCamelCase，如 `Photography`；ID 用稳定的 kebab-case，如 `camera-and-vision`、`history-query`。ID 必须与 Catalog 键完全一致。配置、公开简介和指令分别使用 Skill.json、Description.md 和 Instructions.md；路径相对 Resources，不允许绝对路径、反斜杠和 `.` / `..` 段。Skill 引用其他 Skill 使用 ID，不使用文件路径。

## Skill.json 字段

除标明可选的字段外，所有下列字段必须填写，空列表写 `[]`。资源只保存静态 Skill 声明。

| 字段 | 类型 | 作用与校验 |
| --- | --- | --- |
| `version` | integer | Schema 版本，当前固定为 4。 |
| `id` | string | 稳定 Skill 身份，必须等于 Catalog 中的键。 |
| `revision` | integer | Skill 内容修订号，必须大于 0；流程、绑定、依赖等语义变更应递增，以便历史快照区分。不是 Schema version。 |
| `owner` | string | 可选。填写运行时 Agent ID 时，该 Skill 仅由对应角色加载，通用发现和加载只使用省略此字段的共享 Skill。 |
| `dependencies` | string array | 前置 Skill ID，最多 16 个；应唯一、必要且可加载。禁止自依赖和环，加载器先展开依赖再加入当前 Skill。 |
| `useActions` | object array | 本 Skill 所需函数绑定，最多 128 项，canonical path 不重复。组合后的总目录还受容量与函数合法性限制。 |
| `useInstructions` | string array | 显式数组按顺序加载，空数组不加载。 |
| `useStates` | string array | 必填；最多 16 个公开名称，拒绝重复和非法命名空间；未知来源按项观察为unknown并附诊断。 |

### useActions 绑定

| 字段 | 作用与规范 |
| --- | --- |
| `path` | `Domain.Module.function` 三段 canonical 路径，必须有所属实现维护的中立声明和真实执行路由；通信函数声明由 Agents/Support/Communication 维护。 |
| `callType` | 共享 Skill 使用 `action`，包括查询、设备操作、展示。Writer 专属 Skill 使用原生 `tool`。`scheduling` 只用于 Basic Interaction 注册系统调度 `wait`：path 固定为 `Scheduling.Wait.wait`、alias 为 `wait`、无 channel，不对应 Action 声明。 |
| `alias` | 组合目录内唯一的模型调用标识，作为 Action 的 XML 别名或原生 Tool 名称。保留名为 `wait`，仅可由 `scheduling` 绑定使用。 |
| `channel` | Action 必填，用于调度。原生 Tool 省略此字段。 |

加载了 Skill 即可使用其全部合法 Action，不再维护 Agent 权限上限或重复登记函数。不同 Skill 引用同一 path 时，绑定完全相同才合并；类型、别名或 Channel 冲突时整个加载失败。不同 path 也不能共享 alias；同一函数不能同时作为 Action 和 Tool。send 是 Assistant 的 peer control。Task 与 Skill 控制是 Assistant 的固定 control（见 [Agent controls](../Support/Core/Capability/README.md#agent-controls)），Skill 不登记、不释放、不教学 control，control 声明与用法指南由拥有者 Agent 目录的 `Controls.json` 与 `Controls.md` 提供；Skill.json 出现 `useControls` 时解码拒绝。组合器没有固定 Task 函数注入特例。

灵动岛展示由 Agent 自有运行流程调用 `UI.Island.*` 内部工具。Skill 目录只注册模型可用的业务能力。

`doc`、参数 Schema、必填项、约束和完成语义来自函数自己的 `@Action`，不放在 Skill.json。函数不注册 examples；全部业务示例放在 Instructions.md，并遵循真实函数参数与当前 Skill 别名。

[WriterWorkspace](Skills/WriterWorkspace/Skill.json) 是 Writer 的基础作品库 Skill，[WriterFileEditing](Skills/WriterFileEditing/Skill.json) 随编辑域自动激活。作品库 Skill 声明 Gateway 工具与 Writer 本地工具，区分已知 ID 的直接打开或进入与按名称搜索。文件编辑 Skill 依赖作品库 Skill，编辑阶段同时提供两者的工具与教学。详见 [Writer 工作区分域](../Writer/README.md#作品库与工作区分域)。

BasicInteraction 的表情部分教学连续表情演出，提供指定子集的纯串行及“每项语音与表情并行、各项串行”的全量 XML 示例；“所有表情”按当前 express 参数枚举逐项展开，不包括仅用于清除状态的 clear。演出使用完成时等待过渡与恢复的 express，保持默认 Speech/Display Channel；不为有限演出创建需后续用户决策的 Task。资源 revision 随教学递增。`wait` 的注册和全部用法教学（成对作用域、嵌套、自闭 `time` 延时）由 BasicInteraction 的 Skill.json 与 Instructions 拥有；`time` 以秒为单位，教学要求优先整秒，仅在确需不足一秒时用小数。Actions 与共享目录不再提供 wait 条目。

### useStates 与当前事实

BasicInteraction读取ui.home.expression、agents.applicationcontrol、agents.writer、ui.navigation、全局ui.windows及八个platform.*来源；相机与视觉读取 actions.camera、ui.camera、ui.album；RobotInteraction读取actions.robot。加载与依赖合并后去重排序，每次实际模型请求重新读取。CURRENT STATE是数据，不是指令；availability和value表达来源事实。Task／Skill从Agent私有决策快照生成AGENT CONTEXT，不注册公共task。

声明不启动设备；释放Skill不销毁Container。来源由上层装配提供，Container显式维护快照schema，不使用运行时反射。容量、生命周期和采集失败见[Context](../Support/Context/README.md)。

## 指令加载

Instructions.md 是静态教学，经共享提示词加载器以空变量集渲染。业务请求和状态由运行时作为数据装配。指令编写、示例和评审流程见 [Agents 开发规范](../AGENTS.md#skill-编写与评审)。

摄影流程应读取相机事实、按需打开或切换、拍摄并使用返回的 previewID；询问保存或重拍时保留任务，保存或关闭清空后按已确认结果结束。重拍直接拍摄，旧图在会话缓存内继续可读。普通相机控制请求可在效果确认后完成。摄影对话由 Assistant 维护，不 send 给 VisionPerception 来回对话。

## 加载、释放与 Task 生命周期

Assistant 的 [Controls.md](Agents/Assistant/Controls/Controls.md) 按概念、上下文、决策、控制动作效果、生命周期、反馈/失败组织。Skill 明确提供教学、函数、State 选择及依赖；自身变量 `task` 保留持续目标，单次工作的多次模型请求不构成设置它的充分理由。六项 Agent 控制由 Controls.md 教学，分别负责读写自身变量（`state.set` / `state.clear` / `state.get`）、加载／卸载 Skill（`skill.load` / `skill.unload`）和向同伴发送委托正文（`send`）。加载和卸载影响后续请求，清除 `task` 提交终态及摘要。`send` 的送达回执独立于同伴接纳与完成。参数和协议由 canonical 声明与 Core 拥有，JSON 只注册现有绑定、状态及指令来源。

显式 `skill.unload` 可移除确认不再需要且允许释放的近期非基础根；基础项、非根依赖和仍被其他根依赖的指定 Skill 拒绝卸载。Skill 与 `task` 无关：目标既不持有 Skill，也不回收 Skill。加载/卸载失败原子保留先前能力状态；`state.set` 替换已有目标时旧目标收尾与新目标创建是分阶段流程，不能承诺收尾后的创建失败会自动恢复旧目标。

Assistant 的 [Controls.md](Agents/Assistant/Controls/Controls.md) 在加载前按用户目标匹配 AVAILABLE SKILLS / DELEGATABLE AGENTS 的公开 description。当前函数目录只是已加载子集；函数缺失不能直接作为不支持该能力的依据。事实已足够时直接回答，已声明函数直接按教学使用，缺失且匹配的能力通过 skill.load 获取；用户明确的跨轮目标通过 state.set 写入 task。加载成功后的下一请求才读取新增私有教学并执行，不把加载与业务动作拼在一轮。拒绝能力前检查公开目录；实际未提供的操作或加载/执行失败仍如实报告，不重复加载。Assistant 的 [Controls.md](Agents/Assistant/Controls/Controls.md) 只描述通用能力发现流程，不包含具体业务场景或业务 Skill ID 示例；业务教学由对应 Skill 拥有。只有公开目录没有相关 Skill 或可委托 Agent 时，才能说明能力未提供；加载或执行失败须报告具体阻塞，不能等同于能力不存在。

默认基础能力由 Agent 的 `skills` 初始化。`skill.load` / `skill.unload` 是 Assistant 的 `self` control，不经 Channel 调度；加载后下一轮使用提交后的函数，无需再次加载。输入参数及数组编码以 Agent.Skill canonical 元数据为准。

Assistant 的 [Controls.md](Agents/Assistant/Controls/Controls.md)先检查CURRENT STATE：已有足够事实直接回答，不加载Skill或重复查询；确需执行单步控制/查询/拍摄且函数缺失时才使用 skill.load，多轮持续目标设置 `task`。一次拍照且无后续操作不强制设置。直接加载只扩展能力，不建立目标；默认决策链可包含多次模型请求；Skill 跨链保留，加载/合法调用重置为 5，未使用的完整用户决策扣 1。`task` 先设定目标及可判断的完成条件，等待用户时持续保留；模型根据真实结果判断目标达成或用户明确替换目标后用 state.clear（或带 note 的 state.set）并如实记录结果；用户取消时清除并记录未完成结果。可恢复动作失败不等于目标结束；运行时决策异常进入 failed，重启进入 interrupted。一次性历史查询仅在所需函数缺失时直接加载，多轮筛选与确认示例使用 `task`。

加载先展开依赖，再验证资源、canonical 函数、别名和 Channel，全部成功后提交；任一失败保持原状态。依赖链最多 8 层，展开后最多 16 个 Skill，有效函数含内部能力最多 128 项，Channel 最多 16 个。

每次模型请求持有不可变的 Skill / 函数快照。切换只影响后续请求，本轮不能立即调用刚加载的函数；成功结果通过现有屏障进入 ReACT。无 Task 的近期 Skill 在五次闲置用户决策后回收，内部 ReACT 不扣次数；清除目标不改变 Skill，基础 Skill 继续有效。Skill 不保存运行时业务状态，不能通过修改文件恢复旧任务或重放动作。

后台工作使用 send(agent_id,text) 转述用户要求。接收角色拥有自己的能力、Context 和工作流，决定如何接纳与回报。

## 已有 Skill

| ID / 目录 | 职责 |
| --- | --- |
| basic-interaction / BasicInteraction | 常驻基础交互：表情与聆听 Action、窗口独立性规则及基础 State 选择。Task／Skill 控制不在 Skill 内，见 Assistant 的 Controls.md。 |
| robot-interaction / RobotInteraction | 按需加载的机械臂交互动作及其状态观察。 |
| camera-and-vision / [Photography](Skills/Photography/Skill.json) | 相机与视觉。负责后台视觉、跟随、镜头、拍照、录像和预览处置。 |
| history-query / HistoryQuery | 历史只读查询 Actions。 |
| application-control / ApplicationControl | 应用配置、资源、设备及 UI 能力。 |
| web-browsing / WebBrowsing | 远程网页多窗口访问、原窗口跨站跳转、正文与截图观察及逐屏导航。 |
| writer-workspace / WriterWorkspace | Writer 私有作品库查询与进入。 |
| writer-file-editing / WriterFileEditing | Writer 私有文件读写、渲染和收尾。 |

资源仅随 App 打包，无远程下载或热更新。

[Resources 总览](README.md) · [Agent 规范](AgentAuthoring.md) · [Skill 组合实现](../Support/AgentSkillLoader.swift) · [Task / Context](../Support/Context/README.md)

## 当前流程规则

相机与视觉 Skill 的匹配摄影 Task 在保存或视频处置结果确认后可以结束，Camera 窗口独立保留。只有用户明确关闭或丢弃照片时才执行 closeCamera，closeCamera 成功无返回值（仅失败回传），直接确认关闭并清除匹配目标。Task 取消/替换、打开新窗口不授权关窗。关闭直接清空未保存照片；待处置视频需先明确保存或忽略。关闭失败或取消时保留 Task 和已提交的保存结果。Capture 关闭不关闭背景视觉。独立拍照／保存操作不创建 Task；重拍保留原 Task、窗口及先前缓存照片。

Assistant 的 [Controls.md](Agents/Assistant/Controls/Controls.md) 要求以 AGENT STATE 中的 task 和匹配目标判断关闭：无 Task 单步完成只回复。明确目标切换可释放无关非基础近期 Skill；不确定是否放弃旧目标时先问是否继续实际 Task，保持等待状态。明确替换或正常目标完成不重复询问。continueDecision 只继续同一输入剩余新目标；释放 Skill 不代表相机/照片清理。相机与视觉 Skill 与 HistoryQuery 的完成示例遵循同一规则。

Assistant 全双工中，清除 `task`（附 note）成功即提交前台终态和历史摘要。被打断时，根据 AGENT STATE 中的当前目标及回执决定是否再发起控制。短暂岔题保留目标，去向不明时询问，明显转向且旧目标无需继续时可主动清除。Control 与语音、显示等 channel 各自调度。

历史查询只复制 list 返回的完整 dialog_number；notFound 允许一次重新 list 和一次基于实际 ID 的修正 read，不猜测 ID 或无限重试。业务参数与 media_N 等引用来自真实反馈。语法、Channel/wait 和资源冲突由 Core/Gateway 契约决定，Skill 不重复定义。

## 公开 State 边界

内置 Skill 使用 schema v4，并显式声明 useStates。每轮模型请求读取当前加载的 Skill 和依赖项声明的集合。卸载影响后续请求的选择。

[容器上下文契约](../Support/Context/README.md)

Assistant Controls.md 统一承载 Skill 选择/Task/失败规则，BasicInteraction 承载表情、聆听与窗口规则，相机与视觉 Skill 教学配置、后台视觉及拍摄流程；少量示例验证主要分支，不重述通用协议。公开 State 位于独立的每轮系统数据消息。

Assistant 的 [Controls.md](Agents/Assistant/Controls/Controls.md) 教学明确六种控制的 XML 形式、skill.load 和 skill.unload 的独占响应与后续请求边界，查询旁支保留 Task，最近 Skill 不因短暂旁支而主动释放。相机与视觉 Skill 明确 busy/needsSettings 门、真实 preview ID、已保存事实与未执行保存的区别；普通忽略成功经窗口收尾后结束匹配 Task，明确重拍则保留。RobotInteraction 以 connected/controlAvailable 同时为 true 作为动作前提，不以环境查询覆盖明确阻断。ApplicationControl/HistoryQuery 使用各自子系统 Channel 的精确 XML 查询别名与跨请求结果示例。教学保持简洁，增加有针对性的正向分支示例，不扩展新能力。

当前 Action 目录中的查询可直接使用，不重复加载 Skill；摄影示例区分“用户请求但尚未拍摄”和“收到成功反馈”，缺失 displayedMediaID 字段也不能传空 ID。沿用相同能力、用例和执行错误，不通过放宽校验兼容错误输出。

模型以当前声明判断 Skill 可用，不要求模型计算私有闲置倒计时。倒计时/容量/所有权仍由运行时实现，教学只保留跨轮使用、显式卸载与闲置回收和不可由释放代替设备清理的边界。

## 调用协议

共享 Skill 的 Action 绑定须声明 Channel。BasicInteraction 的 wait 使用独立的 scheduling 绑定。Channel 是并发概念：只有互斥或占用同一表面、设备、会话的 Action 才共用 Channel，彼此独立的使用不同 Channel 才能并行。当前划分：`Camera`（拍摄与录像，除 cancelCapture）、`CameraCancel`（cancelCapture，取消不得排在被取消的拍照倒计时之后）、`Vision`（Vision.open/close/flip/retry，与拍摄会话独立）、`Window`（openPage 与 Window.*）、`Web`（Web.browse/snapshot/inspect/navigate）、`Device`（Bluetooth.control/readStatus）、`ModelResources`（download/cancel/snapshot）、`History`（History.list/read）、`Provider`（Provider.readSettings）、`Robot`、`ListeningControl`，以及运行时固定的 `Speech`、`Display`（字幕与表情）和 `Listening`。只读查询不再共用 Query。跨 Skill 复用的同一 path（如 Window.*）绑定必须一致。Channel 不替代资源 permit，硬件冲突仍由 Shell 裁决。WriterWorkspace 与 WriterFileEditing 归 Writer 所有，使用原生 Tool 并省略 Channel。

## 基础相册实施契约

相机与视觉 Skill 将媒体保存至 App 相册。系统导出与删除由相册界面处理。

## 对话打开相册

application-control增加App相册导航示例，并推进Skill revision；只开放页面导航，不增加相册读取、删除或系统导出能力。

## Container 上下文

schema v4统一声明useActions/useStates/useInstructions；Action绑定保持原授权与执行语义。useInstructions 声明要加载的指令文件，空数组不加载文档，显式列表按顺序加载；路径必须是Skill目录内Markdown。未知已选择来源按项返回unknown及路径诊断，Skill声明不会创建来源或启动设备。

## Basic native State selection

BasicInteraction selects agents.applicationcontrol, agents.writer, ui.navigation and ui.windows plus platform.system.time/power/thermal/network/permissions/audio/locale/accessibility. PlatformKit owns the native facts; AgentStateBindings projects the complete producer-owned Business dictionary and wraps bounded JSON for CURRENT STATE on each actual request. BasicInteraction teaches sampled time, unknown data, path-versus-endpoint and permission-versus-execution boundaries without adding functions or authority. There is no location/motion/depth/proximity/magnetic-attachment collection in this selection. [Source contracts](../Support/Context/README.md#container-context-read-path) own details.

## Prefer current facts before query selection

BasicInteraction answers questions directly from sufficient CURRENT STATE facts before selecting functions or loading Skills. It does not reload facts through a query merely because the user asks a state question. Only missing or stale facts justify a query that actually provides them; unknown/unavailable values are not readiness. Requested effects still require registered execution and real feedback. agents.applicationcontrol provides the role-owned application summary; specific status/resource/history queries supply details under their own contracts. No generic environment query is registered.

RobotInteraction teaches six-axis anatomy, absolute counts versus relative degrees, base-left/right viewpoint, native speed/acceleration units, per-axis limits and ordered compound examples. Relative motor requests use fresh executor feedback; undefined absolute angle origins require clarification. Its revision identifies this teaching contract.

## Exact State selection

useStates declares exact canonical paths.

| Skill | `useStates` |
| --- | --- |
| BasicInteraction | agents.applicationcontrol、agents.writer、ui.navigation、ui.windows、ui.home.expression，以及上节八个 platform.system.* |
| RobotInteraction | actions.robot、actions.robot.motion |
| Camera and Vision | actions.camera、actions.camera.preview、ui.camera、ui.album、ui.windows、platform.vision.camera |
| ApplicationControl | ui.windows |
| WebBrowsing | ui.web、ui.windows、actions.web.screenshot |
| HistoryQuery、WriterWorkspace、WriterFileEditing | 空 |

Each actual request samples only those nodes and uses the producer-owned complete Business dictionary. Child indices are not recursively expanded or injected. Runtime, health/issues and diagnostic history stay outside Assistant State. Internal engineering callers can explicitly inspect a tree independently of Skills. Loading/release changes future disclosure only; no loadState, automatic wakeup, device action or changed execution authority is introduced.

BasicInteraction 常驻提供 `Speech.Listening.startListening` / `stopListening`，别名同函数名，使用独立 ListeningControl Channel。退出语音意图仅输出 stopListening，不在关闭后追加语音或自动重开，不隐式改变业务 Task；启动只响应明确用户意图。参数和真实完成语义由 [Listening Actions](../../Actions/Speech/Listening/README.md) 拥有。

The Camera and Vision and ApplicationControl Skills share six Window.* aliases and select ui.windows. BasicInteraction selects the window summary. Camera.Capture.open creates the photo window. Camera and Vision instructions emit known open/settings/capture steps in one response; result-dependent disposition remains a later request within the existing prompt budget.

Camera and Vision binds Vision.open/close/flip/retry to Camera.Perception on the Vision Channel. Capture and recording use their own Camera Channel. The Skill reads platform.vision.camera for native facts and actions.camera for the active lensOwner. Only the applicable visible owner can switch the lens. Minimizing the capture window retains capture and hands lens authority to visible enabled background vision.

`camera-and-vision` 通过 Vision.open 处理后台视觉、跟踪和人物跟随，通过 Capture Actions 处理拍摄。两个工作流保持独立，明确的组合请求分别启用。ApplicationControl 的 openPage vision 打开视觉设置页。

## Photo/video workflow

Camera and Vision exposes Capture.configure/cancelCapture plus Video.startRecording/stopRecording/saveVideo/ignoreVideo using the existing Camera channel (cancelCapture alone uses CameraCancel so it is not queued behind the pending countdown) and stable aliases. configureCamera updates supplied settings and preserves omitted fields. A native countdown belongs to takePhoto; video startup, file completion and App album inclusion remain distinct. takePhoto requires an already open visible Camera window and selects photo mode; optional delaySeconds overrides only this shot, with no configureCamera step. openCamera and takePhoto can be generated together and execute in order on Camera. Spoken preparation can sit between them in the same response: separate wait groups join open and then speech before capture, because speech uses a different Channel. startRecording internally opens/restores the Camera window and selects video mode. openCamera waits for a ready preview and completes without a business value. Same-channel lens or settings preparation can follow it in one response; window commands use ui.windows. startRecording accepts optional durationSeconds for timed recording. Photo and video have parallel start/disposition/Task-cleanup examples. startRecording defaults to awaiting the ready file before model feedback; VisionPerception's fixed interactive Tool requests startup-only acknowledgement. Ready feedback supplies actual media identity, fileName and duration, and requires an authorized save/ignore decision rather than reporting recording in progress. The Skill gives spoken preparation before recording, then relies on the stop button or configured duration while listening is paused. Failed/uncertain work is not automatically replayed. Confirmed photo save or video save/ignore can complete the matching Task while retaining its window; explicit close/discard intent is independent, as is background Vision.

## Web skills

Assistant 的 [Controls.md](Agents/Assistant/Controls/Controls.md) 公开 Assistant 自身变量 state.set/clear/get、Skill 加载 skill.load/unload 和后台消息 send(agent_id,text)。后台目标、补充和停止都使用正文。接收 Agent 自行决定如何处理，公开目录提供角色职责。Writer 私有工具与作品业务由 Writer 拥有。

Assistant 的 [Controls.md](Agents/Assistant/Controls/Controls.md) 要求将同伴报告视为证据，不由通知重委托；运行时拥有播放排空后的启听衔接，不靠模型生成startListening。

Skill description是未加载时的能力发现索引，说明触发场景与职责边界。BasicInteraction默认观察全窗口摘要；web-browsing提供远程页面观察、定向截图和导航；application-control 提供通用窗口控制；跨边界目标根据拥有者公开 description 路由，不在其他 Skill 重复角色用途。没有加载Skill不等于不存在可加载能力；指令要求根据可用目录加载后再判断可见性，State摘要与实际正文/截图证据明确区分。

Camera and Vision selects actions.camera.preview and exposes loadPreviewImage/unloadPreviewImage. Teaching distinguishes temporary previewID from persistent mediaID, default latest from explicit selections, and actual image attachments from metadata. Skill absence stops transmission without disposing of cached photos.

Camera and Vision teaches actual numeric preview_N references and system-State attachment-order mapping for images merged into the current user input.

Camera and Vision describes the20-image FIFO window session, stable local preview_N labels, retained pending/saved entries, reload and close expiry. A single load appends a selection. A batch load sets up to five explicit photos, with the latest photo filling a free slot. saveAllPhotos saves all pending photos, and closing clears temporary previews without a photo prompt.

BasicInteraction 的 Lifetime and completion 独占通用窗口生命周期教学：窗口独立于 Task/Skill，操作一个窗口不隐式关闭其他窗口，关闭/丢弃需要明确意图。Assistant 身份不承载窗口流程；相机与视觉、ApplicationControl、WebBrowsing 只说明各自操作与完成语义，不复制通用规则或嵌入跨业务场景。资源 revision 随教学更新。

Assistant 的 Controls.md 教授前台 Task、委派、补充输入、取消、Skill 生命周期和执行反馈；BasicInteraction 教授 `wait` 排序与延时、表情、聆听控制、窗口独立性和基础 State 的读法。`wait` 的排序规则见 BasicInteraction 的 Instructions，通用 XML 与 Channel 规则见 [共享输出协议](Agents/Shared/OutputProtocol.md)，语音与字幕呈现见 [Assistant 角色指令](Agents/Assistant/Instructions.md)。

WebBrowsing 的 useStates 同时选择 actions.web.screenshot、ui.web 与 ui.windows。图片是单张当前视口 State；Instructions 说明替换/失效及无历史选择，Action 回执 screenshotID 只作当次证据，不用于历史图片加载。
