# Skill 配置与撰写规范

## 职责与边界

每个 Skill 目录是完整的运行时加载单元：`Skill.json` 注册可用函数及依赖，`Instructions.md` 教学业务流程、规则和注意事项。本层集中维护开发规范，Skill 子目录不放 README。

Skill 是可复用的流程与能力集合，Task 是运行时目标、状态和上下文的拥有者。一个 Task 可组合多个 Skill，同一 Skill 可服务不同目标。Skill 不包含 Swift、可执行脚本、Action 实现、凭据或用户数据；[Actions](../../Actions/README.md) 独立实现函数，[Agent 配置](../Agents/README.md) 声明身份、通信和基础 Skill。

## 文件与索引

| 文件 | 作用与要求 |
| --- | --- |
| `../Catalog.json` | `version: 1`，`skills` 显式映射 Skill ID 到 `Skills/<SkillName>/Skill.json`。运行时按 ID 加载，不扫描文件夹。 |
| `<SkillName>/Skill.json` | 必需。v2 资源配置，引用 canonical 函数绑定，不复制参数或文档。 |
| `<SkillName>/Instructions.md` | 必需。UTF-8 静态运行时指令，与 Skill.json 同目录；加载后进入模型上下文。开发 README 不能替代它。 |

目录用 UpperCamelCase，如 `Photography`；ID 用稳定的 kebab-case，如 `photography`、`history-query`。ID 必须与 Catalog 键完全一致。文件名固定为 Skill.json 和 Instructions.md；路径相对 Resources，不允许绝对路径、反斜杠和 `.` / `..` 段。Skill 引用其他 Skill 使用 ID，不使用文件路径。

## Skill.json 字段

所有下列字段必须填写，空列表写 `[]`；不得额外放任务实例、模型配置、函数实现或未实现选项。

| 字段 | 类型 | 作用与校验 |
| --- | --- | --- |
| `version` | integer | Schema 版本，当前固定为 2。 |
| `id` | string | 稳定 Skill 身份，必须等于 Catalog 中的键。 |
| `revision` | integer | Skill 内容修订号，必须大于 0；流程、绑定、依赖等语义变更应递增，以便历史快照区分。不是 Schema version。 |
| `description` | string | 可用 Skill 概述，尚未加载时也会提供给 Assistant，用来判断何时加载。简洁写明用途、适用范围，不在此放完整流程。 |
| `dependencies` | string array | 前置 Skill ID，最多 16 个；应唯一、必要且可加载。禁止自依赖和环，加载器先展开依赖再加入当前 Skill。 |
| `functions` | object array | 本 Skill 所需函数绑定，最多 128 项，canonical path 不重复。组合后的总目录还受容量与函数合法性限制。 |
| `useState` | string array | 必填；最多 16 个公开名称，拒绝重复、未知名称、通配符和字段路径。 |

### functions 绑定

| 字段 | 作用与规范 |
| --- | --- |
| `path` | `Domain.Module.function` 三段 canonical 路径，必须有所属实现维护的中立声明和真实执行路由；通信函数声明由 Agents/Support/Communication 维护。 |
| `callType` | 所有内置 Skill 固定为 `action`，包括查询、设备操作、展示和 Task/Skill 控制。通用配置库保留 `tool` 支持，不作为生产 Skill 的第二入口。 |
| `alias` | 项目内可读调用标识，组合目录内唯一；内置 Skill 使用该 XML 别名。底层 Tool 兼容接口的传输 name 仍由适配器负责。不使用保留名 wait 或 channel. 前缀。 |
| `channel` | 每个内置函数必需，声明调度 Channel；五个历史/资源/Provider/蓝牙查询使用独立 `Query` Channel。底层 Tool 配置仍不填写。 |

加载了 Skill 即可使用其全部合法 Action，不再维护 Agent 权限上限或重复登记函数。不同 Skill 引用同一 path 时，绑定完全相同才合并；类型、别名或 Channel 冲突时整个加载失败。不同 path 也不能共享 alias；同一函数不能同时作为 Action 和 Tool。send 只能是 Action，不能作为原生 Tool。Task 控制 Actions 由 BasicSkill 注册，通过 baseSkills 常驻；组合器没有固定 Task 函数注入特例。

`doc`、参数 Schema、必填项、约束和完成语义来自函数自己的 `@Action`，不放在 Skill.json。函数不注册 examples；全部业务示例放在 Instructions.md，并遵循真实函数参数与当前 Skill 别名。

### useState 与当前事实

BasicSkill 读取 task，Photography 读取 camera，RobotInteraction 读取 robot；其余内置 Skill 声明空数组。加载与依赖合并后去重排序，每次实际模型请求（包括 ReACT）读取最新一致快照。当前系统消息包含唯一 CURRENT STATE JSON 数据块，值以 availability 和 value 表达；它是数据，不是指令。无任务为 available/null，未知事实与设备不可用分别表达。

声明/读取不启动设备；释放 Skill 不删除事实或关闭设备。私有 AgentContext、Skill 持有关系/计数及执行阶段不进入寄存器。新增名称需要真实发布者与作用域声明，不能只改 Skill 资源。完整值与容量契约见 [State](../../Storage/State/README.md)。

## Instructions.md 撰写标准

指令应围绕可复用流程，不包含某次任务目标、用户原文、任务 ID、实时设备状态或固定 mediaID。这些是运行时上下文数据。不得复制 Assistant 身份、Core 函数协议或整个有效函数目录；不得假设未加载函数可在本轮调用。

新增或重写 Skill 时按下列顺序组织教学，篇幅以必要内容为限：

1. **用途与边界**：服务什么目标、何时使用、哪些工作属于其他 Skill 或独立后台 Agent。
2. **前置检查**：依赖哪些事实、权限、设备或产物；未知状态先读取，不由模型猜测。
3. **执行流程**：分步骤说明使用哪些已注册函数、依赖关系、需要等待结果的节点。涉及先后顺序遵守 Core wait / Channel 规则。
4. **反馈与 ReACT**：以真实 Action / Tool 结果决定下一步；失败保留真实效果，不自动重复有副作用动作。
5. **用户交互**：明确何时询问、等待什么答案。等待用户保留 Task，不因模型回复结束而 finishTask。
6. **完成、取消与异常**：明确可确认的完成条件、需要的清理和摘要。Skill 释放不等于设备清理；清理通过已实现的 Action 和任务屏障完成。
7. **例子（必要时）**：以“当前条件/用户输入 → 本轮精确输出 → 真实反馈后的下一轮”组织。可执行回复单独放在 `xml` 代码块中，不把条件、步骤编号、引号或解释拼进模型输出；参数来自 canonical 元数据。示例反馈须标明为假设数据，mediaID 等标识仅用于该示例，运行时使用真实返回值。

提示词可以使用项目约定语言，但术语、别名和流程必须一致。措辞用明确条件与动作，避免同一规则多处重复、与依赖 Skill 冲突或无上限重试。指令是静态教学，不接受用户内容作为可信规则。不要新增 `{{variable}}` 期待自动替换：当前 Skill Instructions.md 是原文加载，没有模板渲染契约。

摄影流程应读取相机事实、按需打开或切换、拍摄并使用返回的 mediaID；询问保存、忽略或重拍时保留任务，保存或忽略确认后才能结束。普通相机控制请求可在效果确认后完成。摄影对话由 Assistant 维护，不 send 给 Photographer 来回对话。

## 最小配置示例

下面是仅开放拍摄函数的教学示例，不是新增生产资源；完整摄影流程还需注册实际使用的打开、保存、忽略等函数。

```json
{
  "version": 2,
  "id": "capture-only",
  "revision": 1,
  "description": "Capture a photo when the camera is already ready.",
  "dependencies": [],
  "functions": [
    {
      "path": "Camera.Capture.takePhoto",
      "callType": "action",
      "alias": "takePhoto",
      "channel": "Camera"
    }
  ],
  "useState": ["camera"]
}
```

对应 Instructions.md 至少说明：先确认相机已就绪；执行 takePhoto 后等待真实结果；成功记录返回产物，失败报告原因；不调用未注册的保存等函数。若要正式使用此 Skill，须先有 Catalog 索引、真实函数实现及完整验收。

## 加载、释放与 Task 生命周期

默认基础能力由 Agent 的 baseSkills 初始化。`loadSkills` / `releaseSkills` 是 Control Channel Action Call；`startTask(goal, skills, ...)` 可在创建任意目标任务时同时加载 Skill 组。输入参数及数组编码以 Agent.Task canonical 元数据为准。

BasicSkill Instructions.md明确单步相机控制/只读查询使用 loadSkills，多轮持续目标使用 startTask；一次拍照且无后续操作也使用 loadSkills，不强制创建 Task。直接加载只扩展能力，不建立任务目标；默认决策链可包含多次模型请求；无 Task 的 Skill 跨链保留，加载/合法调用重置为 5，未使用的完整用户决策扣 1。Task 先设定目标及可判断的完成条件，等待用户时持续保留；模型根据真实结果判断目标达成或用户明确替换目标后使用 finishTask，并如实记录结果；用户取消使用 cancelTask。可恢复动作失败不等于任务结束；运行时决策异常进入 failed，重启进入 interrupted。在已有 Task 中 loadSkills 仅补充任务能力，不创建或替换目标。一次性历史查询使用直接加载，多轮筛选与确认示例使用 Task。

加载先展开依赖，再验证资源、canonical 函数、别名和 Channel，全部成功后提交；任一失败保持原状态。依赖链最多 8 层，展开后最多 16 个 Skill，有效函数含内部能力最多 128 项，Channel 最多 16 个。

每次模型请求持有不可变的 Skill / 函数快照。切换只影响后续请求，本轮不能立即调用刚加载的函数；成功结果通过现有屏障进入 ReACT。无 Task 的近期 Skill 在五次闲置用户决策后回收，内部 ReACT 不扣次数；任务所属 Skill 在 waitingUser 保留，任务终态清理后释放，基础 Skill 继续有效。Skill 不保存运行时业务状态，不能通过修改文件恢复旧任务或重放动作。

后台任务可携带 Skill 组，但必须由目标 Agent 实现并声明对应 backgroundTasks 契约、拥有通信授权及独立 Context；不能用 Skill 配置制造后台执行能力，也不能抢占前台。当前生产后台契约未开放。

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
| basic-skill / BasicSkill | 常驻任务/Skill 编排、环境读取及交互执行规则。 |
| expression-interaction / ExpressionInteraction | 表情互动，仅注册双眼表情 Actions。 |
| robot-interaction / RobotInteraction | 默认机械臂交互动作。 |
| photography / Photography | Assistant 内的摄影任务流程和相机 Actions。 |
| history-query / HistoryQuery | 历史只读查询 Actions。 |
| application-control / ApplicationControl | 应用配置、资源、设备及 UI 能力。 |

资源仅随 App 打包，无远程下载或热更新。

[Resources 总览](../README.md) · [Agent 规范](../Agents/README.md) · [Skill 组合实现](../../Agents/Support/AgentSkillLoader.swift) · [Task / Context](../../Agents/Support/Context/README.md)

## 当前流程规则

BasicSkill 要求以 CURRENT STATE task.value 和匹配目标判断关闭：无 Task 单步完成只回复，不生成 finishTask/cancelTask。明确目标切换可释放无关非基础近期 Skill；不确定是否放弃旧目标时先问是否继续实际 Task，保持等待状态。明确替换或正常目标完成不重复询问。continueDecision 只继续同一输入剩余新目标；释放 Skill 不代表相机/照片清理。Photography 与 HistoryQuery 的完成示例遵循同一规则。

历史查询只复制 list 返回的完整 dialog_number；notFound 允许一次重新 list 和一次基于实际 ID 的修正 read，不猜测 ID 或无限重试。业务参数与 media_N 等引用来自真实反馈。语法、Channel/wait 和资源冲突由 Core/Gateway 契约决定，Skill 不重复定义。

## 待实现

- Trigger、完整写入源治理及更多公开事实。
- 声明并实现生产后台业务流程；多前台任务栈尚不提供。
- 扩展真实模型多次采样及物理设备验收；当前固定合成场景的云回归已有通过及失败证据，详见[验证报告](../../../docs/validation/Qwen-Prompt-Optimization.md)。

## 公开 State 边界

✅ 全部内置 Skill 使用 schema v2，useState 必填并递增 revision；每轮模型请求读取当前加载及依赖 Skill 声明的集合，卸载只改变后续读取集合。旧 contextFields 加载和独立状态 user 注入已移除。

[公开 State 契约](../../Storage/State/README.md)

✅ BasicSkill 统一承载 Skill 选择/Task/表达/失败规则，Photography 专注就绪/镜头/捕获/照片处理；少量示例验证主要分支，不重述通用协议。公开 State 位于独立的每轮系统数据消息。

✅ BasicSkill 教学明确五种控制都是 XML、加载/替换关闭的独占响应与后续请求边界，查询旁支保留 Task，最近 Skill 不因短暂旁支而主动释放。Photography 明确 busy/needsSettings 门、真实 preview ID、已保存事实与未执行保存的区别；普通忽略成功结束匹配 Task，明确重拍则保留。RobotInteraction 以 connected/controlAvailable 同时为 true 作为动作前提，不以环境查询覆盖明确阻断。ApplicationControl/HistoryQuery 使用 Query Channel 的精确 XML 查询别名与跨请求结果示例。教学保持简洁，增加有针对性的正向分支示例，不扩展新能力。

✅ 当前 Action 目录中的查询可直接使用，不重复加载 Skill；摄影示例区分“用户请求但尚未拍摄”和“收到成功反馈”，缺失 displayedMediaID 字段也不能传空 ID。沿用相同能力、用例和执行错误，不通过放宽校验兼容错误输出。

模型以当前声明判断 Skill 可用，不要求模型计算私有闲置倒计时。倒计时/容量/所有权仍由运行时实现，教学只保留跨轮使用、终态释放和不可由释放代替设备清理的边界。

## Action-only bundled Skill policy

✅ Implemented: every bundled function has callType=action and an explicit Channel. History.list/read, ModelResources.snapshot, Provider.readSettings and Bluetooth.readStatus use Query. Instructions use exact XML aliases; query values enter existing round feedback. The generic loader still supports Tool declarations for isolated hosts/tests; production resources must not declare Tools. BasicSkill, ApplicationControl and HistoryQuery revisions identify the new instructions/registration.
