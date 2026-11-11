# Skill 配置与撰写规范

## 职责与边界

每个 Skill 目录是完整的运行时加载单元：`Skill.json` 注册可用函数及依赖，`Instructions.md` 教学业务流程、规则和注意事项。本层集中维护开发规范，Skill 子目录不放 README。

Skill 是可复用的流程与能力集合，Task 是运行时目标、状态和上下文的拥有者。一个 Task 可组合多个 Skill，同一 Skill 可服务不同目标。Skill 不包含 Swift、可执行脚本、Action 实现、凭据或用户数据；[Actions](../../Actions/README.md) 独立实现函数，[Agent 配置](../Agents/README.md) 声明身份、通信和基础 Skill。

## 文件与索引

| 文件 | 作用与要求 |
| --- | --- |
| `../Catalog.json` | `version: 1`，`skills` 显式映射 Skill ID 到 `Skills/<SkillName>/Skill.json`。运行时按 ID 加载，不扫描文件夹。 |
| `<SkillName>/Skill.json` | 必需。v3 资源配置，引用 canonical 函数绑定。 |
| `<SkillName>/Instructions.md` | 必需。UTF-8 静态运行时指令，与 Skill.json 同目录；加载后进入模型上下文。开发 README 不能替代它。 |

目录用 UpperCamelCase，如 `Photography`；ID 用稳定的 kebab-case，如 `photography`、`history-query`。ID 必须与 Catalog 键完全一致。文件名固定为 Skill.json 和 Instructions.md；路径相对 Resources，不允许绝对路径、反斜杠和 `.` / `..` 段。Skill 引用其他 Skill 使用 ID，不使用文件路径。

## Skill.json 字段

除标明可选的字段外，所有下列字段必须填写，空列表写 `[]`。资源只保存静态 Skill 声明。

| 字段 | 类型 | 作用与校验 |
| --- | --- | --- |
| `version` | integer | Schema 版本，当前固定为 3。 |
| `id` | string | 稳定 Skill 身份，必须等于 Catalog 中的键。 |
| `revision` | integer | Skill 内容修订号，必须大于 0；流程、绑定、依赖等语义变更应递增，以便历史快照区分。不是 Schema version。 |
| `description` | string | Skill 概述。共享 Skill 的摘要供 Assistant 在加载前选择。简洁写明用途和适用范围。 |
| `owner` | string | 可选。填写运行时 Agent ID 时，该 Skill 仅由对应角色加载，通用发现和加载只使用省略此字段的共享 Skill。 |
| `dependencies` | string array | 前置 Skill ID，最多 16 个；应唯一、必要且可加载。禁止自依赖和环，加载器先展开依赖再加入当前 Skill。 |
| `useActions` | object array | 本 Skill 所需函数绑定，最多 128 项，canonical path 不重复。组合后的总目录还受容量与函数合法性限制。 |
| `useInstructions` | string array | 显式数组按顺序加载，空数组不加载。 |
| `useStates` | string array | 必填；最多 16 个公开名称，拒绝重复和非法命名空间；未知来源按项观察为unknown并附诊断。 |

### useActions 绑定

| 字段 | 作用与规范 |
| --- | --- |
| `path` | `Domain.Module.function` 三段 canonical 路径，必须有所属实现维护的中立声明和真实执行路由；通信函数声明由 Agents/Support/Communication 维护。 |
| `callType` | 共享 Skill 使用 `action`，包括查询、设备操作、展示和 Task/Skill 控制。Writer 专属 Skill 使用原生 `tool`。 |
| `alias` | 组合目录内唯一的模型调用标识，作为 Action 的 XML 别名或原生 Tool 名称。保留名为 `wait`。 |
| `channel` | Action 必填，用于调度。原生 Tool 省略此字段。 |

加载了 Skill 即可使用其全部合法 Action，不再维护 Agent 权限上限或重复登记函数。不同 Skill 引用同一 path 时，绑定完全相同才合并；类型、别名或 Channel 冲突时整个加载失败。不同 path 也不能共享 alias；同一函数不能同时作为 Action 和 Tool。send 只能是 Action，不能作为原生 Tool。Task 控制 Actions 由 BasicSkill 注册，通过 baseSkills 常驻；组合器没有固定 Task 函数注入特例。

`doc`、参数 Schema、必填项、约束和完成语义来自函数自己的 `@Action`，不放在 Skill.json。函数不注册 examples；全部业务示例放在 Instructions.md，并遵循真实函数参数与当前 Skill 别名。

[WriterWorkspace](WriterWorkspace/Skill.json) 是 Writer 的基础作品库 Skill，[WriterFileEditing](WriterFileEditing/Skill.json) 随编辑域自动激活。作品库 Skill 声明 Gateway 工具与 Writer 本地工具，区分已知 ID 的直接打开或进入与按名称搜索。文件编辑 Skill 依赖作品库 Skill，编辑阶段同时提供两者的工具与教学。详见 [Writer 工作区分域](../../Agents/Writer/README.md#作品库与工作区分域)。

✅ ExpressionInteraction 教学连续表情演出，提供指定子集的纯串行及“每项语音与表情并行、各项串行”的全量 XML 示例；“所有表情”按当前 express 参数枚举逐项展开，不包括仅用于清除状态的 clear。演出使用完成时等待过渡与恢复的 express，保持默认 Speech/Display Channel；不为有限演出创建需后续用户决策的 Task。资源 revision 随教学递增，通用编排规则由 Core scheduling 模板拥有。

### useStates 与当前事实

BasicSkill读取agents.applicationcontrol、agents.writer、ui.navigation、全局ui.windows及八个platform.*来源；Photography读取actions.camera、ui.camera、ui.album；RobotInteraction读取actions.robot。加载与依赖合并后去重排序，每次实际模型请求重新读取。CURRENT STATE是数据，不是指令；availability和value表达来源事实。Task／Skill从Agent私有决策快照生成AGENT CONTEXT，不注册公共task。

声明不启动设备；释放Skill不销毁Container。来源由上层装配提供，Container显式维护快照schema，不使用运行时反射。容量、生命周期和采集失败见[Context](../../Agents/Support/Context/README.md)。

## Instructions.md 撰写标准

指令应围绕可复用流程，不包含某次任务目标、用户原文、任务 ID、实时设备状态或固定 mediaID。这些是运行时上下文数据。不得复制 Assistant 身份、Core 函数协议或整个有效函数目录；不得假设未加载函数可在本轮调用。

新增或重写 Skill 时按下列顺序组织教学，篇幅以必要内容为限：

1. **用途与边界**：服务什么目标、何时使用、哪些工作属于其他 Skill 或独立后台 Agent。
2. **前置检查**：依赖哪些事实、权限、设备或产物；未知状态先读取，不由模型猜测。
3. **执行流程**：分步骤说明使用哪些已注册函数、依赖关系、需要等待结果的节点。涉及先后顺序遵守 Core wait / Channel 规则。
4. **反馈与 ReACT**：以真实 Action / Tool 结果决定下一步；失败保留真实效果，不自动重复有副作用动作。
5. **用户交互**：明确何时询问、等待什么答案。等待用户保留 Task，不因模型回复结束而 task.end。
6. **完成、取消与异常**：明确可确认的完成条件、需要的清理和摘要。Skill 释放不等于设备清理；清理通过已实现的 Action 和任务屏障完成。
7. **例子（必要时）**：以“当前条件/用户输入 → 本轮精确输出 → 真实反馈后的下一轮”组织。可执行回复单独放在 `xml` 代码块中，不把条件、步骤编号、引号或解释拼进模型输出；参数来自 canonical 元数据。示例反馈须标明为假设数据，mediaID 等标识仅用于该示例，运行时使用真实返回值。

提示词可以使用项目约定语言，术语、别名和流程须一致。用明确条件与动作，避免重复规则、与依赖 Skill 冲突或无上限重试。Skill Instructions.md 是静态教学，经共享提示词加载器以空变量集渲染。业务请求和状态由运行时作为数据装配。

摄影流程应读取相机事实、按需打开或切换、拍摄并使用返回的 previewID；询问保存或重拍时保留任务，保存或关闭清空后按已确认结果结束。重拍直接拍摄，旧图在会话缓存内继续可读。普通相机控制请求可在效果确认后完成。摄影对话由 Assistant 维护，不 send 给 Photographer 来回对话。

## 最小配置示例

下面是仅开放拍摄函数的教学示例，不是新增生产资源；完整摄影流程还需注册实际使用的打开、保存、忽略等函数。

```json
{
  "version": 3,
  "id": "capture-only",
  "revision": 1,
  "description": "Capture a photo when the camera is already ready.",
  "dependencies": [],
  "useActions": [
    {
      "path": "Camera.Capture.takePhoto",
      "callType": "action",
      "alias": "takePhoto",
      "channel": "Camera"
    }
  ],
  "useStates": ["actions.camera"],
  "useInstructions": ["Instructions.md"]
}
```

对应 Instructions.md 至少说明：先确认相机已就绪；执行 takePhoto 后等待真实结果；成功记录返回产物，失败报告原因；不调用未注册的保存等函数。若要正式使用此 Skill，须先有 Catalog 索引、真实函数实现及完整验收。

## 加载、释放与 Task 生命周期

BasicSkill Instructions 按概念、上下文、决策、控制动作效果、生命周期、反馈/失败组织。Skill 明确提供教学、函数、State 选择及依赖；Task 保留持续目标和完成条件，单次工作的多次模型请求不构成创建 Task 的充分理由。九项控制 Action 的教学与注册对应：加载/释放影响后续请求，start 可携带初始能力，end/cancel 先进入收尾再终态，delegate 的接纳不等于完成，send 只补充已有目标，聆听控制独立于 Task。参数和协议由 canonical 声明与 Core 拥有，JSON 只注册现有绑定、状态及指令来源。

显式 releaseSkills 可移除确认不再需要且允许释放的近期或任务非基础根，Task 本身继续存在；基础项、非根依赖和仍被其他根依赖的指定 Skill 拒绝释放。通常保留目标需要的能力并在终态清理，不能把使用建议写成运行时禁止。加载/释放失败原子保留先前能力状态；Task 替换预校验、旧目标收尾、新目标创建是分阶段流程，不能承诺收尾后的创建失败会自动恢复旧目标。

BasicSkill 在加载前按用户目标匹配 AVAILABLE SKILLS / DELEGATABLE AGENTS 的公开 description。当前函数目录只是已加载子集；函数缺失不能直接作为不支持该能力的依据。事实已足够时直接回答，已声明函数直接按教学使用，缺失且匹配的单次能力通过 loadSkills 获取；新持续目标通过 task.start(skills) 获取。加载成功后的下一请求才读取新增私有教学并执行，不把加载与业务动作拼在一轮。拒绝能力前检查公开目录；实际未提供的操作或加载/执行失败仍如实报告，不重复加载。BasicSkill 只描述通用能力发现流程，不包含具体业务场景或业务 Skill ID 示例；业务教学由对应 Skill 拥有。只有公开目录没有相关 Skill 或可委托 Agent 时，才能说明能力未提供；加载或执行失败须报告具体阻塞，不能等同于能力不存在。

默认基础能力由 Agent 的 baseSkills 初始化。`loadSkills` / `releaseSkills` 是 Control Channel Action Call；`task.start(description, skills?)` 在创建本 Agent 的前台目标任务时同时加载所需 Skill 组；BasicSkill 教学要求携带已知必要的初始 Skill 数组，成功反馈后下一轮使用提交后的函数，无需再 loadSkills。已有 Skill 可随启动转为任务持有；后续出现新的缺失能力才额外加载。输入参数及数组编码以 Agent.Task canonical 元数据为准。

BasicSkill Instructions.md先检查CURRENT STATE：已有足够事实直接回答，不加载Skill或重复查询；确需执行单步控制/查询/拍摄且函数缺失时才使用loadSkills，多轮持续目标使用startTask。一次拍照且无后续操作不强制创建Task。直接加载只扩展能力，不建立任务目标；默认决策链可包含多次模型请求；无 Task 的 Skill 跨链保留，加载/合法调用重置为 5，未使用的完整用户决策扣 1。Task 先设定目标及可判断的完成条件，等待用户时持续保留；模型根据真实结果判断目标达成或用户明确替换目标后使用 task.end，并如实记录结果；用户取消使用 task.cancel。可恢复动作失败不等于任务结束；运行时决策异常进入 failed，重启进入 interrupted。在已有 Task 中 loadSkills 仅补充任务能力，不创建或替换目标。一次性历史查询仅在所需函数缺失时直接加载，多轮筛选与确认示例使用 Task。

加载先展开依赖，再验证资源、canonical 函数、别名和 Channel，全部成功后提交；任一失败保持原状态。依赖链最多 8 层，展开后最多 16 个 Skill，有效函数含内部能力最多 128 项，Channel 最多 16 个。

每次模型请求持有不可变的 Skill / 函数快照。切换只影响后续请求，本轮不能立即调用刚加载的函数；成功结果通过现有屏障进入 ReACT。无 Task 的近期 Skill 在五次闲置用户决策后回收，内部 ReACT 不扣次数；任务所属 Skill 在 waitingUser 保留，任务终态清理后释放，基础 Skill 继续有效。Skill 不保存运行时业务状态，不能通过修改文件恢复旧任务或重放动作。

后台委派使用 task.delegate 发送目标和用户输入。接收角色拥有自己的能力与 Context，并由内部工作流判断执行、追问或拒绝。

## 开发与 Review 标准

1. 先判断是否能复用现有 Skill 或组合 Skill；新增目录必须取得仓库要求的批准。不要为每个具体 Task 目标创建一个固定 Skill。
2. 先更新本目录规范或 owning Agent 设计中受影响的契约，再修改配置和教学。注册与教学一起 review，实际使用的每个函数必须已开放。Action 实现不是 Skill 注册理由；只注册当前需求、流程实际用到的函数。纯 App 编排/反馈 Action 可不属于任何 Skill，不能为了覆盖实现而扩张模型目录。
3. 添加 Catalog 映射并核对 ID、revision、依赖、canonical 元数据；检查与其他可组合 Skill 的函数及规则冲突。
4. 修改流程需同时检查等待、结束、取消、异常及有副作用重试行为；涉及 Context 新数据应修改 Builder / Schema，不能用提示词冒充事实。
5. 验证依赖环、深度、超限、未知函数、重复 path / alias、Action/Tool 冲突和加载失败不改状态；验证请求快照、ReACT 配对及等待用户生命周期。配置行为变更运行 `./scripts/check.sh`，完整 Xcode 可用时运行 `./scripts/build-ios.sh`，核对最终 App 资源；真实设备和模型单独验收。
6. 不用当前 Skill 配置重新解释历史记录。历史应使用当轮 Skill revision 和目录证据；缺失目录时明确返回预览失败。

## 已有 Skill

| ID / 目录 | 职责 |
| --- | --- |
| basic-skill / BasicSkill | 常驻任务/Skill 编排、自动 State 选择及交互执行规则。 |
| expression-interaction / ExpressionInteraction | 表情互动，仅注册双眼表情 Actions。 |
| robot-interaction / RobotInteraction | 按需加载的机械臂交互动作及其状态观察。 |
| photography / Photography | Assistant 内的摄影任务流程和相机 Actions。 |
| history-query / HistoryQuery | 历史只读查询 Actions。 |
| application-control / ApplicationControl | 应用配置、资源、设备及 UI 能力。 |
| web-browsing / WebBrowsing | 远程网页多窗口访问、原窗口跨站跳转、正文与截图观察及逐屏导航。 |

资源仅随 App 打包，无远程下载或热更新。

[Resources 总览](../README.md) · [Agent 规范](../Agents/README.md) · [Skill 组合实现](../../Agents/Support/AgentSkillLoader.swift) · [Task / Context](../../Agents/Support/Context/README.md)

## 当前流程规则

Photography 的匹配摄影 Task 在保存或视频处置结果确认后可以结束，Camera 窗口独立保留。只有用户明确关闭或丢弃照片时才执行 closeCamera，收到 operation=close、enabled=false 后确认关闭并完成匹配目标。Task 取消/替换、打开新窗口不授权关窗。关闭直接清空未保存照片；待处置视频需先明确保存或忽略。关闭失败或取消时保留 Task 和已提交的保存结果。Capture 关闭不关闭背景视觉。独立拍照／保存操作不创建 Task；重拍保留原 Task、窗口及先前缓存照片。

BasicSkill 要求以 AGENT CONTEXT task 和匹配目标判断关闭：无 Task 单步完成只回复，不生成 task.end/task.cancel。明确目标切换可释放无关非基础近期 Skill；不确定是否放弃旧目标时先问是否继续实际 Task，保持等待状态。明确替换或正常目标完成不重复询问。continueDecision 只继续同一输入剩余新目标；释放 Skill 不代表相机/照片清理。Photography 与 HistoryQuery 的完成示例遵循同一规则。

Assistant 全双工中，`task.end` 成功即提交前台终态和历史摘要；明确结束当前目标时需实际调用，单独回复确认会保留任务。Control 与语音、显示等 channel 各自调度。

历史查询只复制 list 返回的完整 dialog_number；notFound 允许一次重新 list 和一次基于实际 ID 的修正 read，不猜测 ID 或无限重试。业务参数与 media_N 等引用来自真实反馈。语法、Channel/wait 和资源冲突由 Core/Gateway 契约决定，Skill 不重复定义。

## 待实现

- Trigger、完整写入源治理及更多公开事实。
- 声明并实现生产后台业务流程；多前台任务栈尚不提供。
- 扩展真实模型多次采样及物理设备验收；当前固定合成场景的云回归已有通过及失败证据，详见[验证报告](../../../docs/validation/Qwen-Prompt-Optimization.md)。

## 公开 State 边界

✅ 全部内置 Skill 使用 schema v3，useStates 必填并递增 revision；每轮模型请求读取当前加载及依赖 Skill 声明的集合，卸载只改变后续读取集合。旧 contextFields 加载和独立状态 user 注入已移除。

[容器上下文契约](../../Agents/Support/Context/README.md)

✅ BasicSkill 统一承载 Skill 选择/Task/表达/失败规则，Photography 专注就绪/镜头/捕获/照片处理；少量示例验证主要分支，不重述通用协议。公开 State 位于独立的每轮系统数据消息。

✅ BasicSkill 教学明确五种控制都是 XML、加载/替换关闭的独占响应与后续请求边界，查询旁支保留 Task，最近 Skill 不因短暂旁支而主动释放。Photography 明确 busy/needsSettings 门、真实 preview ID、已保存事实与未执行保存的区别；普通忽略成功经窗口收尾后结束匹配 Task，明确重拍则保留。RobotInteraction 以 connected/controlAvailable 同时为 true 作为动作前提，不以环境查询覆盖明确阻断。ApplicationControl/HistoryQuery 使用 Query Channel 的精确 XML 查询别名与跨请求结果示例。教学保持简洁，增加有针对性的正向分支示例，不扩展新能力。

✅ 当前 Action 目录中的查询可直接使用，不重复加载 Skill；摄影示例区分“用户请求但尚未拍摄”和“收到成功反馈”，缺失 displayedMediaID 字段也不能传空 ID。沿用相同能力、用例和执行错误，不通过放宽校验兼容错误输出。

模型以当前声明判断 Skill 可用，不要求模型计算私有闲置倒计时。倒计时/容量/所有权仍由运行时实现，教学只保留跨轮使用、终态释放和不可由释放代替设备清理的边界。

## Action-only bundled Skill policy

✅ Implemented: every bundled function has callType=action and an explicit Channel. History.list/read, ModelResources.snapshot, Provider.readSettings and Bluetooth.readStatus use Query. Instructions use exact XML aliases; query values enter existing round feedback. The generic loader still supports Tool declarations for isolated hosts/tests; production resources must not declare Tools. BasicSkill, ApplicationControl and HistoryQuery revisions identify the new instructions/registration.

## 基础相册实施契约

✅ Photography保存语义改为App相册；系统导出及删除不开放给Skill。

## 对话打开相册

✅ application-control增加App相册导航示例，并推进Skill revision；只开放页面导航，不增加相册读取、删除或系统导出能力。

## Container 上下文

✅ schema v3统一声明useActions/useStates/useInstructions；Action绑定保持原授权与执行语义。缺省useInstructions为Instructions.md，空数组不加载文档，显式列表按顺序加载；路径必须是Skill目录内Markdown。未知已选择来源按项返回unknown及路径诊断，Skill声明不会创建来源或启动设备。

## Basic native State selection

BasicSkill selects agents.applicationcontrol and ui.navigation plus platform.system.time/power/thermal/network/permissions/audio/locale/accessibility. PlatformKit owns the native facts; AssistantStateBindings projects the complete producer-owned Business dictionary and wraps bounded JSON for CURRENT STATE on each actual request. BasicSkill teaches sampled time, unknown data, path-versus-endpoint and permission-versus-execution boundaries without adding functions or authority. There is no location/motion/depth/proximity/magnetic-attachment collection in this selection. [Source contracts](../../Agents/Support/Context/README.md#container-context-read-path) own details.

## Prefer current facts before query selection

BasicSkill answers questions directly from sufficient CURRENT STATE facts before selecting functions or loading Skills. It does not reload facts through a query merely because the user asks a state question. Only missing or stale facts justify a query that actually provides them; unknown/unavailable values are not readiness. Requested effects still require registered execution and real feedback. agents.applicationcontrol provides the role-owned application summary; specific status/resource/history queries supply details under their own contracts. No generic environment query is registered.

RobotInteraction teaches six-axis anatomy, absolute counts versus relative degrees, base-left/right viewpoint, native speed/acceleration units, per-axis limits and ordered compound examples. Relative motor requests use fresh executor feedback; undefined absolute angle origins require clarification. Its revision identifies this teaching contract.

## Exact State selection

useStates declares exact canonical paths. BasicSkill selects agents.applicationcontrol, ui.navigation and eight platform.system.* nodes. ExpressionInteraction selects ui.home.expression; RobotInteraction selects actions.robot plus actions.robot.motion; Photography selects actions.camera/ui.camera/ui.album. ApplicationControl and HistoryQuery add no State sources. There is no alias, wildcard or implicit ancestor/descendant selection.

Each actual request samples only those nodes and uses the producer-owned complete Business dictionary. Child indices are not recursively expanded or injected. Runtime, health/issues and diagnostic history stay outside Assistant State. Internal engineering callers can explicitly inspect a tree independently of Skills. Loading/release changes future disclosure only; no loadState, automatic wakeup, device action or changed execution authority is introduced.

BasicSkill 常驻提供 `Speech.Listening.startListening` / `stopListening`，别名同函数名，使用独立 ListeningControl Channel。退出语音意图仅输出 stopListening，不在关闭后追加语音或自动重开，不隐式改变业务 Task；启动只响应明确用户意图。参数和真实完成语义由 [Listening Actions](../../Actions/Speech/Listening/README.md) 拥有。

Photography and ApplicationControl share six Window.* aliases and select ui.windows; BasicSkill has no window catalog or State additions. Camera.Capture.open remains the only photo-window creation entry. Photography instructions retain separate-request capture/disposition examples within the existing prompt budget.

ApplicationControl exposes background Vision.open/close/flip/retry aliases for Camera.Perception.*Vision. Photography retains Capture aliases and window controls. Both select platform.vision.camera for actual native facts. Only the visible lensOwner may flip; minimizing photo retains capture and hands lens authority to visible enabled background vision. BasicSkill’s resident catalog is unchanged.

BasicSkill routes 打开视觉／跟踪／人物或姿态跟随 to application-control and Vision.open; 拍照／拍摄照片 to photography and its capture Actions. The unloaded Skill descriptions carry this distinction, and both Skill instruction sets repeat the boundary after loading. openPage vision is model settings navigation, not vision activation. No new Camera Actions are resident in BasicSkill.

## Photo/video workflow

Photography exposes Capture.configure/cancelCapture plus Video.startRecording/stopRecording/saveVideo/ignoreVideo using the existing Camera channel and stable aliases. configureCamera updates supplied settings and preserves omitted fields. A native countdown belongs to takePhoto; video startup, file completion and App album inclusion remain distinct. takePhoto/startRecording internally open or restore the Camera window and select their mode; ordinary capture needs no separate openCamera/configureCamera. openCamera waits for a ready preview and completes without a business value. Same-channel lens or settings preparation can follow it in one response; window commands use ui.windows. startRecording accepts optional durationSeconds for timed recording. Photo and video have parallel start/disposition/Task-cleanup examples. startRecording defaults to awaiting the ready file before model feedback; Photographer's fixed interactive Tool requests startup-only acknowledgement. Ready feedback supplies actual media identity, fileName and duration, and requires an authorized save/ignore decision rather than reporting recording in progress. The Skill gives spoken preparation before recording, then relies on the stop button or configured duration while listening is paused. Failed/uncertain work is not automatically replayed. Confirmed photo save or video save/ignore can complete the matching Task while retaining its window; explicit close/discard intent is independent, as is background Vision.

BasicSkill revision37 routes 拍照/录像 to Photography without adding permanent camera Actions. Prompt regression budgets are26,000 UTF-8 bytes for the base catalog and38,000 with Photography, which includes six additional Action declarations and recording lifecycle instructions. These are context-size checks, not model or device acceptance.

Photography与ApplicationControl增加Island.setPresentation以及ui.island事实，模型以size=compact/expanded控制已有内容，现有目标任务提供detail可展开，任务详情与实时状态按内容分组独立选择，状态切换保留任务描述和手动收起偏好；不指定尺寸/动画，不把展示当业务完成。Basic常驻目录不变。摄影加载提示预算38000 UTF-8字节用于增加的通用展示声明和State说明，基础提示预算26000；实际装配长度由PromptTemplateTests验证。

## Web skills


BasicSkill 默认暴露前台 task.start/end、独立 task.delegate、支持可选 agent_id 的 task.cancel/send，教学前台 scope 与后台通信的区别。同一目标的 start/delegate 是按所有者选择的平级入口；其他 Agent 用途和输入要求从 DELEGATABLE AGENTS 读取，BasicSkill 不维护角色职责清单。忙碌、补充、取消清理与接纳不等于完成采用通用规则。Catalog 没有 Writing Skill 或 Artifact_library；Writer 原生工具目录与作品业务由该角色自己拥有。Assistant 当前 Skills 均声明 Action 和显式 Channel；通用 Skill schema 保留 tool 能力。

BasicSkill 要求将同伴报告视为证据，不由通知重委托；运行时拥有播放排空后的启听衔接，不靠模型生成startListening。

Skill description是未加载时的能力发现索引，说明触发场景与职责边界。BasicSkill默认观察全窗口摘要；web-browsing提供远程页面观察、定向截图和导航；application-control 提供通用窗口控制；跨边界目标根据拥有者公开 description 路由，不在其他 Skill 重复角色用途。没有加载Skill不等于不存在可加载能力；指令要求根据可用目录加载后再判断可见性，State摘要与实际正文/截图证据明确区分。

Photography selects actions.camera.preview and exposes loadPreviewImage/unloadPreviewImage. Teaching distinguishes temporary previewID from persistent mediaID, default latest from explicit selections, and actual image attachments from metadata. Skill absence stops transmission without disposing of cached photos.

Photography teaches actual numeric preview_N references and system-State attachment-order mapping for images merged into the current user input.

Photography describes the20-image FIFO window session, stable local preview_N labels, retained pending/saved entries, reload and close expiry. A single load appends a selection. A batch load sets up to five explicit photos, with the latest photo filling a free slot. saveAllPhotos saves all pending photos, and closing clears temporary previews without a photo prompt.

BasicSkill 的 Lifetime and completion 独占通用窗口生命周期教学：窗口独立于 Task/Skill，操作一个窗口不隐式关闭其他窗口，关闭/丢弃需要明确意图。Assistant 身份不承载窗口流程；Photography、ApplicationControl、WebBrowsing 只说明各自操作与完成语义，不复制通用规则或嵌入跨业务场景。资源 revision 随教学更新。

BasicSkill 教授前台 Task、委派、补充输入、取消、Skill 生命周期、聆听控制和执行反馈。通用 XML、Channel 和 wait 规则见 [System 输出协议](../Agents/System/OutputProtocol.md)，语音与字幕呈现见 [Assistant 角色指令](../Agents/Assistant/Instructions.md)。
