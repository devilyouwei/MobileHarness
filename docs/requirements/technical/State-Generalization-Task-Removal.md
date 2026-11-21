# 状态机泛化与 Task 的去处

## 背景与决定

Task 最初是 Assistant 维持跨轮目标的机制，后来“委托其他 Agent”也并入同一套 `task.*` 函数、`agent.task.*` 协议和 `AgentTask*` 类型。实际上 Task 只是 Agent 的一种状态；安静、愤怒、说话风格等同类状态没有统一机制。

决定：取消 Task 作为独立概念与专用业务代码。

1. Agent 拥有一份私有、有界、可读写的**状态表**；控制函数 `state.set` / `state.clear` / `state.get` 修改它。开始任务是 `state.set("task", "……")`（系统注入命名空间，实际落入 `agent.assistant.task`），结束是 `state.clear("task", note)`。
2. 状态每轮注入模型上下文（扩展现有 `AGENT CONTEXT` / CURRENT STATE 读取路径），模型每轮都能看到自己的 task、情绪、风格等。
3. 与其他 Agent 通信的 `task.send` 改为独立控制 `send`，不再属于任何状态；同伴委托的跟踪改称 delegation（委托），与状态无关。

## 现状（已读代码）

“task”现在混合了三件事：

| 混合项 | 代码位置 | 说明 |
| --- | --- | --- |
| A. 前台目标状态 | `Agents/Support/Context/AgentTaskSkillState.swift`（`TaskRecord`、`control("task.start"/"task.end")`、`settleTask`）、`Assistant/Controls/AssistantControlExecution.swift`（`controlLocalTaskAndSkills`、`completeForegroundTask`）、`Storage/Database/AssistantTasks/`（`assistant_tasks`、`single_foreground_task` 唯一索引）、历史任务压缩（`reconcileTaskCompressions`、`HistoryTaskCompression`）、UI 设置页历史“Tasks”及 RuntimeLog 的 Task 页 | 单前台槽位 | 取消“单槽位”约束：`task` 就是一个变量，再次 `state.set("task", …)` 即替换；数据库唯一索引移除。 | 单前台槽位；waitingUser/running 状态；结束摘要与压缩 |
| B. Task 作为 Skill 生命周期锚点 | `AgentTaskSkillState`：Task 接管根 Skill、暂停空闲计数、结束回收；`task.start` 的 `skills` 参数 | Skill 与 Task 耦合 |
| C. 同伴委托 | `Support/Core/Communication/AgentTaskSignal.swift`（`AgentTaskScope/Signal/Registry`）、`Support/Communication/AgentTasks.swift`、`AgentFixedTaskCoordinator`、`AgentContracts.swift`、通道 `agent.task`、协议 `agent.task.v1` / `agent.task.events.v1`（各 Agent.json）、`AssistantChatTaskCommunication.swift`、`AssistantChatPeerEvents.swift`、Writer 的 `writer_executions.task_state` | 与 A 只是同名 |
| 已有读侧 | `useStates`、`AgentStateContext`、`ApplicationStateInspection`、公共 `task` 事实（见 [Container-State-Context](Container-State-Context.md)） | 只读；写入源治理原列为后续范围，本需求覆盖其中 Agent 自身变量 |

## 目标设计

### 1. State 是变量：类型化变量与语义变量

State 是 Agent 的**自身变量表**，挂在该 Agent 的 Container State 下（命名空间 `agent.<id>`，与各 Container 发布的 State 同树但不冲突）。持有者仍是 `AgentContextRepository`（事务、revision、validate）。`state.set` 是“Agent 改变自己”的 Control 函数。

- **命名空间由系统注入**：模型只写短名，`state.set("mood", "你目前处于愤怒模式")` 自动落入 `agent.assistant.mood`。模型不能指定命名空间，因此不能写其他 Agent 或 Container 的 State。
- **所有变量值都以字符串存储**；“类型化”指 Swift 预设了键与解析规则。

| 种类 | 定义 | 说明 |
| --- | --- | --- |
| 类型化变量 | Swift 代码预设键、解析/校验规则 | 值在 Swift 中解析后用于逻辑判断，可绑定 Trigger。解析失败原样返回错误，旧值不变。例：`quiet`（布尔） |
| 语义变量 | 无需预设，模型自由命名 | 自然语言字符串，原样进入提示词，如 `mood`、`style`、`waiting`。**`task` 是预设的语义变量**：键预设、值为字符串、需要压缩，将来可绑定“完成后做什么”的 Trigger |

- 语义变量数量上限 32（字节上限随实施在 README 定值，建议总计 ≤ 8 KiB、单值 ≤ 1 KiB）；**超限不报错，自动淘汰最早写入的变量**。预设变量（如 `task`）不被淘汰；单值超长拒绝并报错。
- **每次 `state.set` 记录写入时间**；变量按写入时间排序，时间随值进入提示词。
- **不持久化**：全部在内存；仅初始化时从持久化 Storage 读取的预设变量例外，由所属领域仓库负责。
- 值进入提示词是被引用的文字，不授予任何函数权限。
- 注入：Skill 的 `useStates` 只是“随 Skill 带哪些变量进提示词”，不是授权。基础 Skill 注入自身变量表。

### 1.0 复用现有 Container State 契约

Agent 自身变量就是现有节点 `agents.<id>` 的 business 字段（`AgentStateSnapshot`：business/runtime、`meanings`、`stateValues`、`units`，`collectedAt`）。当前 `agents.assistant` 已有 `taskPhase`；本设计把它扩展为可由 `state.set` 写入的变量集合：

- 读取、`state.get`、Skill 的 `useStates` 选择、容量与 unknown/unavailable 表达全部沿用 `AgentStateContext` 与 `AssistantStateBindings`，不新增读取通路与第二套注入机制；自身变量与其他 Container 的 State 在同一棵树，通过 `agents.assistant` 路径读取。
- 新增的只有**写入侧**：`AgentStateVariables`（`Agents/Support/Context/`）持有值、写入时间、淘汰与 Trigger 调度，`state.set/clear` 是它的 Control 入口；`stateSnapshot()` 把它投影为 business 字段，写入时间随字段投影。

### 1.0.1 声明：Agent.json `states` + Swift 处理器

`Agent.json` 是 Agent 初始化时加载的 skill、state、signals 的配置与校验入口；Skill 目录下的 `Skill.json` 由所有 Agent 共享，其 `useStates` 表示该 Skill 工作所需的状态。沿用 Controls 的模式（JSON 声明 ↔ Swift 枚举/处理器，启动校验双向一致）：

- `Agent.json` 的 `baseSkills` 改名为 `skills`（版本号递增；全部 Agent.json、解码、校验、文档同步）。新增 `states`：预设变量列表，每项 `name`、`kind`（`typed`/`semantic`）、`access`（`model`/`code`，默认 `code`）、`type`（bool/enum 及取值等）、`meaning`（英文说明）、`trigger`（处理器名，可空）。中文说明沿用 `Prompts.<lang>.json` 按变量名翻译，缺失回退英文；说明进入现有 `meanings`/`stateValues`。
- Swift 只注册处理器：类型化变量解析器、Trigger 处理器，按名称绑定。启动双向校验：JSON 中每个 `typed` 变量与 `trigger` 必有 Swift 处理器，Swift 处理器必有 JSON 声明；名称唯一、格式合法、数量不超限；不一致启动即失败，不静默忽略。
- 只有预设语义变量（如 `task`）出现在 `states`；模型自创的语义变量无需声明。
- 不新增文件或目录。

### 1.0.3 模型只读与可读写

两层防线，均在 `state.set/clear` 的执行入口强制，不依赖提示词：

1. **命名空间**：模型只写短名并被注入到自身 `agents.<id>` 下，Camera、UI、Platform 等 Container 的 State 不可达，无需逐项声明。
2. **自身节点内的只读项**：自身节点里也有仅由 Agent 代码写入的变量（如已加载 Skill 数、`taskPhase` 一类运行事实、由宿主写入的开关）。`states` 每项增加 `access`：`model`（模型可写）或 `code`（仅 Swift 写，模型只读），默认 `code`，需显式声明 `model` 才开放。`code` 项仍按 `useStates` 注入、可被 `state.get` 读，但不在 `state.set/clear` 的可写集合内。
   - 凡是 `states` 之外由代码发布到自身节点的字段（business/runtime），一律视为只读；模型自创的语义变量名不得与这些名称或 `code` 项重名，冲突时拒绝。
   - 被拒绝时返回统一错误（如 `stateReadOnly`），不泄露其它信息；该错误记入变更日志。写入失败不改变任何值。
   - 不在提示词里向模型说明哪些只读：预设变量说明只描述含义；可写变量的说明里才出现 `state.set` 用法。
3. 宿主（Swift 代码、Trigger 处理器）经内部写入接口记录 `source=host`，可写任意自身变量，包括 `code` 项；该接口不暴露为 Control。
4. 校验：`access` 取值非法、`typed` 变量缺解析器、`code` 项被 Trigger 以外的路径写入等，由测试覆盖；变更日志的 `source` 区分 model 与 host。

### 1.0.3 写入权限：模型只读与可读写

- **按构造隔离**：模型只能写自己的 `agent.<id>` 命名空间，camera、robot 等 Container 的 State 不可达，无需逐项声明。
- **自身变量 `access`**：`states` 每项带 `access`：`readWrite`（模型可写）或 `readOnly`（仅 Agent 代码/宿主写，如 `quiet` 由宿主按勿扰设置写入）。缺省 `readOnly`，开放给模型必须显式声明。`task` 为 `readWrite`。
- **不在提示词中告知，在 `state.set`/`state.clear` 中拒绝**：对 `readOnly` 变量返回 `controlFailed`（原因 `readOnly`），作为工具结果进入 ReACT，模型据此调整；状态不变，不触发 Trigger。
- **名称碰撞**：模型自创的语义变量不得与预设变量（含 `readOnly`）或 `agents.<id>` 节点已有字段（runtime 计数、`loadedSkills` 等）同名，同样拒绝。
- 宿主/Agent 代码写入走 `source=host`，不受 `access` 限制，仍按类型解析并触发 Trigger。
- 被拒绝的写入也记入变更日志（来源、变量名、`rejected`），在 UI 状态变更 tab 可见。

### 1.0.2 同名合并去重

Agent `skills`、Skill 依赖展开、`useStates`、`useActions`、控制函数与 `states` 声明在加载时一律**按名称合并**：同名只保留一份，进入提示词（教学、函数目录、CURRENT STATE、预设变量说明）也只出现一次。多个来源同名但内容不一致（如 meaning 或类型冲突）视为配置错误，启动/加载时报错，不择一覆盖。卸载按引用计数撤回（见 2.2）。

### 1.1 提示词转换

在现有 CURRENT STATE 读取之上，一个固定的 State→提示词转换函数生成模板块：位置与现有 CURRENT STATE 一致，即用户输入之前的独立 system 块。自身变量按写入时间升序，每行 `名称（写入时间）：值`；时间用自然语言绝对时间（如“2026年11月21日 22:29”），不用时间戳或相对时间，格式由转换函数唯一负责，角色与 Skill 不自行拼接。此块取代 `AGENT CONTEXT.task`，`AGENT CONTEXT` 只保留已加载 Skill 列表。每轮及每次 ReACT 续轮重新生成，历史中不保留旧块（现有规则）。

### 2. Trigger（本期只预留入口）

- Trigger 是 Agent 内聚的预设规则，绑定到类型化变量：变量变化（或将来的时间条件）→ 预设函数/逻辑过程。例：`quiet` 变化 → 输出网关抑制/恢复语音（含 Writer 完成播报；错误、安全提示与用户直接提问的回复不被抑制）；将来 `alarm` 到点 → 触发一次决策。
- 本期实现：Trigger 注册接口（变量名 → 处理器；处理器有界、不重入、失败显式返回且不发布变更）和 `quiet` 一个内置处理器。闹钟、定时循环、用户自定义规则不做，README 说明扩展点。
- 语义变量一般不绑 Trigger；`task` 是第一个绑定 Trigger 的变量：`task` 变化（`state.set` 替换或 `state.clear`）触发“压缩历史对话上下文”函数，沿用现有历史压缩（`reconcileTaskCompressions`），以该次变化的 set→clear 区间为单元，`state.clear` 的 note 作为摘要来源；替换视为先结束旧区间再开始新区间。处理器有界、不重入，失败显式返回且不发布变更。将来的“完成后动作”在同一入口扩展。

### 2.1 `state.get`

- 读取自身变量与 Container 发布的任何状态（如 `ui.windows`、`platform.system.audio`），无授权门槛；`useStates` 只决定随 Skill 注入哪些。
- 复用 AgentStateContext 的单一路径解析、容量与 unknown/unavailable 表达；读取不启动设备、不改变状态。
- **等同有返回值的 Action**：无论成功或失败都返回结果并**必定触发 ReACT 续轮**。成功返回值；路径不存在或读取失败沿用 unknown/unavailable 表达，作为结果返回。
- 结果只作为工具结果（feedback）进入对话历史，按普通历史窗口规则保留与淘汰，**不写入 CURRENT STATE 的 state 块**；需要每轮可见的变量放入 Skill 的 `useStates`。

### 2.1.1 Control 的完成与 ReACT 语义

| 调用 | 成功 | 失败 |
| --- | --- | --- |
| `state.get` | 返回值，触发续轮 | 错误结果，触发续轮 |
| `state.set` / `state.clear` | `.completed`，不强制续轮 | `controlFailed` 错误结果，触发续轮（只读、类型解析失败、单值超限、名称碰撞等），模型据此改口；状态不变 |
| `skill.load` / `skill.unload` | 沿用现有语义（独占整个响应，下一轮生效） | 沿用现有 |
| `send` | `.completed`（对端已接纳） | 错误结果，触发续轮 |

`state.set`/`state.clear`/`send` 成功无返回值；出错一律以异常（Swift `throw`）抛出，由 Control 执行层转换为 `controlFailed` 工具结果并触发 ReACT，不以返回码或成功占位值表达失败；取消（`CancellationError`）原样传播。

### 2.2 Skill 与 State

- `skill.load` / `skill.unload` 取代 `loadSkills` / `releaseSkills`。
- Skill 与目标无关：删除 Task 持有、因 Task 暂停的空闲计数、结束回收。空闲计数、容量淘汰、依赖展开仍按 Skill 自身规则。
- 加载时把 Skill 的 `useStates` 并入注入集合；卸载时只撤回它自己引入的注入项（多 Skill 引用同一变量按引用计数）。**变量的值不因卸载清除**。

### 2.3 Control 函数库重整

Control 是 Assistant 自己执行、不进入 Actions Shell 的内置函数（≤16 条与别名/operation 唯一性校验保持）：

| 别名 | 取代 | 说明 |
| --- | --- | --- |
| `state.set(key,value)` | `task.start` | 写自身变量，类型化变量按规则解析；一次响应可多条（有界） |
| `state.clear(key[,note])` | `task.end` | 清除变量；`note` 进入变更日志 |
| `state.get(path)` | 新增 | 见 2.1 |
| `skill.load(skills)` | `loadSkills` | 仅 Skill，无 Task 参数 |
| `skill.unload(skills)` | `releaseSkills` | 同上 |
| `send(agent_id,text)` | `task.send` | 独立，见 §4 |

需同步重写：`Controls/Controls.json`、`Controls.zh-Hans.json`、`Controls.md`、`Controls.zh-Hans.md`（声明、参数、教学示例；删除 Task 概念与 start/send 二选一）、`AgentControlOperation`、`AssistantControls` 校验、`AssistantControlExecution`（`controlTask` 拆为 state/skill/send 三个入口，删除 Task 分支）、`AgentTaskSkillState.control` 的 operation 字符串、`AssistantControlLink.finishForegroundTask`（改为宿主写变量）。“独占整个响应”只留给 `skill.load/unload`。

### 3. Task 现有语义的去向

| 现有语义 | 去向 |
| --- | --- |
| 单前台槽位 | 取消“单槽位”约束：`task` 是一个变量，再次 `state.set("task", …)` 即替换；数据库唯一索引移除。 |
| `waitingUser/running` 状态 | 取消；“等用户答复”用语义变量 `waiting`；中断/失败仅记录反馈。 |
| `task.start` 的 `skills` | 取消；Skill 与目标无关。 |
| 结束摘要与 `continueDecision` | `state.clear("task", note, continueDecision)`；`note` 作为摘要写入变更日志，是历史压缩的来源。 |
| `assistant_tasks` 表 | 替换为 `agent_state_changes`（变量名、新旧值、note、来源、会话/对话 ID、写入时间、revision）。Storage 沿用“版本不同即重建，不迁移”。 |
| 历史压缩 / 设置页 Tasks | 以 `task` 的 set→clear 区间为单元，数据来自变更日志；UI 标签随之调整。 |
| 重启 | 内存状态随进程丢失；重启时记录一条 host 变更（等价现“记录旧执行中断”）。 |
| 并发约束 | 仅 `skill.load/unload` 保持“独占整个响应”；`state.*` 与 `send` 不占整个响应。 |

### 4. `send` 独立

- 控制别名 `task.send` → `send(agent_id, text)`，`AgentControlOperation.sendMessage`。语义不变：返回时表示对端已接纳，不表示完成。
- 删除“同一目标 start 与 send 二选一”规则；Assistant 可 `state.set("task", "等 Writer 画完图后告诉用户")` 同时 `send`。
- 委托跟踪（Registry/Scope/Signal）重命名为 Delegation：`AgentTaskScope→AgentDelegationScope`、`AgentTaskSignal→AgentDelegationSignal`、`AgentTaskRegistry→AgentDelegationRegistry`、`AgentFixedTaskCoordinator→AgentFixedExecutionCoordinator`；通道 `agent.task→agent.delegation`，协议 `agent.task.v1→agent.delegation.v1`、`agent.task.events.v1→agent.delegation.events.v1`；Writer `task_state→delegation_state`。均为进程内契约，无外部线格式兼容负担，一次改完（版本号递增，Agent.json/Skill 声明及启动校验同步）。
- 同伴事件提示词（`taskQuestion/taskEvents/taskNotice/taskHistory`）改名 peer*。

## 其他需要同时考虑的内容

1. **写入来源**：模型、宿主（如系统设置勿扰）写入都记录 `source`；用户不能直接编辑。
2. **一致性**：写入为 Context 事务，变更日志提交成功后才发布；失败不发布，错误由控制调用返回。
3. **提示词安全**：值进入提示词前做长度/控制字符校验，并作为数据引用。
4. **`state.get`**：读自身及 Container State，结果只在本轮 ReACT 可见。
5. **教学**：`Controls.md`（中英）重写，Task 概念迁入 BasicSkill 对状态的教学；`BasicSkill-Control-Teaching`、Assistant Instructions 同步；`Controls.json` ≤16 条限制与 alias/operation 唯一性校验保持。
6. **并发与批量**：一次响应允许多个 `state.set`（不同键）但最多 4 个，保持有界。
7. **观测**：UI 新增只读“状态变更”可视化日志 tab（来自 `agent_state_changes`，用户不可编辑），取代 RuntimeLog 的 Task 页；`UIStateSnapshot` / `ApplicationStateInspection` 暴露状态表，供诊断。
8. **术语**：`docs/Concepts.md` 删除 Task 行，加入 State 与 Delegation；总体设计第 5 节“Skill composition, Task and model context”、Assistant delegation 章节同步；新增 ADR 记录该决定并与 [ADR 0028](../../adr/0028-inter-agent-communication.md) 的 task 术语建立关系。
9. 不新增目录与第三方依赖；新文件放入既有 `Agents/Support/Context/`（状态表与变更日志端口）与 `Storage/Database/`（`AssistantTasks` 目录改为承载 `agent_state_changes`，目录名同步评估，改名需另行批准）。

## 实施阶段（代码前以本文为准）

| 阶段 | 内容 | 退出条件 |
| --- | --- | --- |
| P0 | 评审本文与开放问题，补 ADR | 开放问题定论 |
| P1 | 状态表、声明 schema、注入、`state.set/clear`、变更日志；类型化/语义变量、`quiet` 与 Trigger 入口先上线（纯增量） | 状态读写/淘汰/时间排序/命名空间隔离/提示词模板测试 |
| P2 | `task` 迁移为预设语义变量；Skill 去除 Task 持有与暂停计数；Control 库重整（state/skill/send 入口、Controls 资源与教学）；历史压缩与持久化按待确认 3 定论；删除 `task.start/end`、`TaskRecord`、`assistant_tasks`、`waitingUser` 路径 | 旧代码与旧测试无残留 |
| P3 | `send` 独立与 Delegation 重命名（含 Writer、Agent.json、通道/协议、提示词） | 全仓无 `agent.task` 通道/`task.send` 引用 |
| P4 | 文档/本地化/资源/Concepts/README 对齐，删除过时描述 | `./scripts/check.sh`、`./scripts/build-ios.sh` 记录结果；模型实测另记 |

涉及文档：`MobileHarness/README.md`、`Agents/README.md`、`Agents/Support/{Context,Core/Communication,Communication}/README.md`、`Agents/Assistant/{README,Controls/README,Workflow/README}.md`、`Agents/Writer/README.md`、`Storage/README.md` 与 Database README、`UI/Settings`、`UI/Components/RuntimeLog` README、`Resources/Skills/README.md`、`docs/Concepts.md`。

## 已定结论

1. State 是 Agent 自身变量表，值均为字符串；类型化变量（Swift 预设解析、可绑 Trigger）与语义变量（自由命名）；`task` 是预设语义变量。
2. 命名空间系统注入，模型只写短名，只能改自己。
3. 语义变量超限自动淘汰最早写入者；每次写入记录时间，按时间排序并进入提示词。
4. 内存存储，不持久化；用户不可编辑，UI 增加只读日志 tab。
5. 固定模板转换函数，输出到用户输入前的独立 system 块。
6. Trigger 入口本期实现两个内置处理器：`task` 变化→压缩历史上下文，`quiet`→抑制语音（含 Writer 播报）；闹钟等不做。
9. 时间为自然语言绝对时间；语义变量数量上限 32。
7. `state.get` 无授权；`useStates` 只是随 Skill 注入。
8. Skill 与目标无关；Control 库重整为 state.set/clear/get、skill.load/unload、send。

## 待确认

1. 语义变量字节上限的具体数值，实施时在 Context README 定值。
