# Context — 私有事务、Task 与 Skill 生命周期

## 职责与关系

AgentContextRepository actor 唯一持有 AgentCore.AgentContext 值，角色决定 schema、校验、保留窗口与业务语义。AgentTaskSkillState 管根 Skill 与任务状态；AgentFixedTaskCoordinator 管确定性 Task 调用及真实结果加入。生产私有 Context 在内存，不编码整份快照或隐式刷盘。

固定任务协调器接纳确定性角色的前台请求及已授权的后续消息。独立后台委派由接收角色的执行入口接纳。

## 文件与职责

| 文件 | 职责 |
| --- | --- |
| [AgentContextRepository.swift](AgentContextRepository.swift) | 唯一私有 Context、FIFO 事务槽、可选提交接口、信号证据与私有快照 |
| [AgentFixedTaskCoordinator.swift](AgentFixedTaskCoordinator.swift) | AgentTaskContextState 校验／恢复、确定性调用关联、固定任务准入及结果加入 |
| [AgentStateContext.swift](AgentStateContext.swift) | 容器只读来源注册、会话代际、按请求采集与关闭 |
| [AgentTaskSkillState.swift](AgentTaskSkillState.swift) | 根 Skill 纯状态转移、Decision 使用集合、依赖／容量和回收；目标记录（`beginTask` / `requestFinish` / `settleTask`）与 Skill 互不依赖 |
| [AgentStateVariables.swift](AgentStateVariables.swift) | Agent 自身变量表、`states` 声明与 schema 校验、写入权限、类型解析、容量淘汰与 Trigger 名 |
| [AgentStatePrompt.swift](AgentStatePrompt.swift) | 变量到提示词的唯一转换：`# AGENT STATE` 块、变量说明与自然语言时间 |

## 外部关系（一层）

```mermaid
flowchart LR
 R["具体角色／Chat Worker"]:::agent
 C["Context 机制"]:::agent
 CO["AgentCore：通用 Context／Task／结果"]:::host
 S["注入领域仓库：持久化由调用者拥有"]:::storage
 R <--> C
 C --> CO
 C -->|"只读能力"| ST["注入的 Container 快照"]:::host
 R --> S
 classDef ui fill:#e0f2fe,stroke:#0284c7,color:#0c4a6e
 classDef platform fill:#dcfce7,stroke:#16a34a,color:#14532d
 classDef model fill:#f3e8ff,stroke:#9333ea,color:#581c87
 classDef storage fill:#fef3c7,stroke:#d97706,color:#78350f
 classDef agent fill:#eef2ff,stroke:#6366f1,color:#312e81
 classDef gateway fill:#ffedd5,stroke:#ea580c,color:#7c2d12
 classDef action fill:#ffe4e6,stroke:#e11d48,color:#881337
 classDef host fill:#f1f5f9,stroke:#64748b,color:#334155
```

Storage 箭头属于调用者，ContextRepository 本身无数据库读写；持久化身份须在绑定 Task 内存状态前由所属流程提交。

## 内部结构

```mermaid
flowchart LR
 R["角色事务入口"]:::agent
 Q["有界 FIFO 事务槽"]:::agent
 C["复制 → 修改 → revision → validate"]:::agent
 H["可选 AgentContextPersistence.commit"]:::host
 V["替换唯一私有值"]:::agent
 P["私有决策快照：Task／Skill 上下文"]:::agent
 K["AgentTaskSkillState：纯状态转移"]:::agent
 F["FixedTaskCoordinator：调用与结果屏障"]:::agent
 R --> Q --> C --> H --> V --> P
 K --> C
 F --> R
 classDef ui fill:#e0f2fe,stroke:#0284c7,color:#0c4a6e
 classDef platform fill:#dcfce7,stroke:#16a34a,color:#14532d
 classDef model fill:#f3e8ff,stroke:#9333ea,color:#581c87
 classDef storage fill:#fef3c7,stroke:#d97706,color:#78350f
 classDef agent fill:#eef2ff,stroke:#6366f1,color:#312e81
 classDef gateway fill:#ffedd5,stroke:#ea580c,color:#7c2d12
 classDef action fill:#ffe4e6,stroke:#e11d48,color:#881337
 classDef host fill:#f1f5f9,stroke:#64748b,color:#334155
```

## 事务、容量与故障

最多 16 个 FIFO 等待者；模型／设备操作不占事务槽。复制、变更、推进 revision、验证及可选 persistence.commit 成功后替换；提交前失败保留原值。首次读取可选 persistence.load 后，验证身份、恢复中断状态并提交推进后的 revision；生产装配不注入此接口。模型上下文采集独立于私有事务；采集失败不改变已提交的业务状态。

recordSignal 只保存有界中立 Data 证据到内存，非 Signal 传输或文件序列化；确定性角色按 4096 滚动保留证据／批次，Core 默认 8192，逻辑 Data 总界 32 MiB。媒体和凭据排除，活跃工作不能被淘汰。持久化 Chat/Task 事实由领域仓库独立提交；重启丢弃热队列，不重放副作用。

热 Skill 状态 schema v5，记录近期根、remainingDecisions、使用次序／会话与至多 32 个在途 Decision 使用集合；目标记录（goal interval）另存于同一状态但与 Skill 无关。非基础展开总数最多 3，正文／增量目录 24 KiB；容量满仅淘汰未保护 LRU，没有空间则原子失败。基础项常驻，定义缓存与激活状态独立，共享依赖按引用保留。

## Agent state variables

Agent 自身变量表（[AgentStateVariables](AgentStateVariables.swift)）是角色私有 Context 的一部分，字符串值，内存存储，随 Context 事务提交，重启丢弃。声明来自 Agent.json 的 `states`（见 [Resources/Agents](../../../Resources/Agents/README.md)），由 `AgentStateSchema` 在配置加载时校验；Swift 侧只提供按类型的解析与按名绑定的 Trigger（目前仅 `task`）。

- **写入**：`set` / `clear` 校验名称（小写字母开头，小写字母、数字、下划线，≤ 32 字节）、写入者（`model` 不能写 `readOnly`，`host` 只能写已声明项）、类型（`bool`/`enum`/`text`，写入前规范化）与单值 ≤ 1 KiB；任何失败抛出且变量不变。清除未设置的变量无变化。重新写入同值只更新时间。
- **容量**：已声明变量不被淘汰；自由变量最多 32 个、名称与值合计 ≤ 8 KiB，超出时不报错，按写入先后淘汰最早者。
- **时间与排序**：每次写入记录时间；`ordered` 按写入时间升序。`showing` 返回叠加了他处持有值的副本（例如当前目标 `task`），仅用于渲染与读取，不写入表。
- **提示词**：[AgentStatePrompt](AgentStatePrompt.swift) 是唯一的转换函数：`block` 生成用户输入前 system 块中的 `# AGENT STATE`（每行 `名称（写入于 自然语言绝对时间）：值`，值以 JSON 字符串引用为数据），`declarations` 生成系统提示中的变量说明（含义与取值，不含访问级别）。模板位于 Shared/RequestContext*.json，中文说明按 `state.<name>` 取 Shared/Descriptions.zh-Hans.json。
- **Trigger**：`AgentStateTrigger` 绑定到声明的 `trigger` 名。`task` 触发目标记录的开始/结束与历史压缩，由 Assistant 的控制执行层处理；闹钟、定时循环等未实现。
- **读取**：`state.get` 的短名读自身变量，带点路径经 AgentStateContext 读取容器状态；无授权门槛，Skill 的 `useStates` 只决定随请求注入哪些来源。

## Task and Skill lifecycle

下图描述非基础根 Skill 的生命周期。控制别名为 skill.load / skill.unload；基础 Skill 常驻，不参与图中的计数与回收。Skill 与目标（`task` 变量及其记录）无关：目标不持有 Skill，不暂停计数，结束也不回收 Skill。

此生命周期处理共享 Skill。依赖展开、函数绑定和教学由 AgentSkillLoader 解析；带 owner 的 Skill 由所属 Agent 的工作流加载，Writer 以工作区域管理其私有 Skill。

```mermaid
flowchart TB
    S0["未加载"] -->|"skill.load"| S1["近期保留：初始 / 续期计数 = 5"]
    S1 -->|"加载或合法使用：重置为 5"| S1
    S1 -->|"完整用户 Decision 结束"| C{"本轮或在途 Decision 使用过？"}
    C -->|"是：保留计数"| S1
    C -->|"否"| D["计数减 1"]
    D -->|"大于 0"| S1
    D -->|"等于 0"| S0
    S1 -->|"skill.unload 成功"| S0
    S1 -->|"容量不足：淘汰未受保护的 LRU"| S0
    S1 -->|"新对话 / 匹配会话关闭 / 全局重置"| S0
```

- 一个完整用户 Decision 可以包含多轮 ReACT，只在 Decision 最终结束时结算一次。
- 取消及会话关闭加入已接纳执行与清理。新输入绑定只将 waitingUser 的目标记录恢复为 running，保留进行中的结束状态。
- 图中的回收指移除根引用并重算依赖；其他根仍引用的共享依赖继续保留。显式卸载基础项、非根项或仍被其他根依赖的指定 Skill 会拒绝，失败不改变状态。
- 在途 Decision 已使用项受容量淘汰保护；没有可淘汰空间时加载失败。定义缓存及已发出的模型请求、历史目录不因回收改变。
- 定向会话关闭清理匹配会话的近期项并保留前台目标。进程重启记录旧执行中断并清空运行时保留。

A goal record is opened by the `task` trigger with an already committed Task ID. The Chat worker validates a candidate, inserts running in SQLite, binds memory, and explicitly closes a failed binding. Recent Skill counters/Decision-use sets, goal registries/views, queues and awaiting-feedback stages remain memory-only. For full-duplex or trusted host clearing, the Context transaction validates the candidate, commits the business record and publishes terminal goal and history state together. Non-duplex model-driven completion marks the goal finishing and settles when its decision joins. A failed or interrupted finish returns the goal to waitingUser.

Goal entry preserves ordinary background context and complete current-goal evidence. Only terminal goals compress their process at the first source position; sources remain queryable. Clearing `task` ends the decision. Camera/media access does not require a goal.

## 中断、完成与限制

中断移除指定 Decision 使用集合而不扣数，保留目标记录/Skill 并回到 waitingUser；匹配会话关闭释放近期 Skill，前台目标持续到显式清除或进程中断。持久化失败由控制调用返回，候选 Context 不发布。取消等待者仍释放已授槽位，错误不降为成功。


AgentStateContext 管理只读来源和会话接纳，不持有目标副本；关闭后旧读取失效。

## Container context read path

AgentStateContext owns a single exact-path resolver and session generations, never facts or a Task mirror. App supplies the classified node reader; AssistantStateBindings adapts the complete Business dictionary. Skill.useStates alone selects sources on each request. No path or field list is duplicated in Assistant. Nested Business arrays/objects remain intact; Runtime, health/issues, metadata and child indices are excluded. Reads never traverse children or start devices.

A missing, unreadable or malformed node has no meaningful value (null, or only nulls): it is omitted from the model context entirely (no null, placeholder or diagnostic is injected), and the State log shows the variable as empty. Sources encode only their value, with no availability wrapper. Exception messages and producer diagnostics are not copied. Other selected sources continue. Cancellation, context closure, generation changes and byte/count limits remain fatal. The adapter bounds raw nodes at256KiB; Context bounds32 names,64 sessions,8KiB/source and16KiB total. Sources are read sequentially outside the lock and generation is checked after collection. Empty selection performs no reads. There is no polling, caching or retry.

Explicit register(source:) remains available for standalone typed hosts/test fixtures (256 entries); those ports own their serialization/failure semantics. Production installs only the unified resolver. Closing removes both ports and resolver. This mechanism does not decide Skill scope or execution permission.

## Private Task and Skill projection

AgentContextRepository remains the private actor-owned source for the role's AgentContext. Chat takes one committed value for the request's Skill IDs, effective function catalog, teaching and AgentTaskSkillState.contextSnapshot(session:). Business reads happen afterward and do not extend the private transaction lock.

The AGENT CONTEXT block contains only `skills`: the current effective loaded ID list, including base and dependency Skills. The Agent's own variables, including the current goal (`task`), are a separate `# AGENT STATE` block (see [Agent state variables](#agent-state-variables)). Task IDs, task arrays, runtime delegation registries/views, grants, input bindings and retention counters are not serialized into either block. The loaded Skill list is the role's effective capability set.

Private Skill transitions, retained history and actual execution outcomes can change later requests, but collecting context does not perform a transition. Goal creation/terminal records are separately committed through the injected Task repository; production does not persist or restore a whole active AgentContext snapshot. Message placement and history/feedback composition belong in [Assistant](../../Assistant/README.md#request-state-assembly), and the cross-module overview belongs in the [overall design](../../../README.md#container-state-read-path).

### Current facts before explicit queries

BasicInteraction uses sufficient CURRENT STATE facts directly before function/Skill selection. The role-owned application summary, passive platform.* facts and selected UI/business snapshots are read for each actual request; reading an observed value does not force its native producer to update. Query Actions provide missing/stale details only under their specific contracts. They may share an owner with State without creating duplicate state. No generic environment query is exposed or registered. Queries cannot override unknown/unavailable readiness, initiate undeclared probes or replace actual effect feedback. The context builder does not suppress model calls automatically; normal catalog/authorization validation rejects removed addresses.

## Reflexivity disclosure boundary

The producer classifies its own complete node data; Assistant chooses Business fields only after the exact Skill selection. Child indices and runtime reader references are separate from state values. Internal programs can explicitly traverse indices through App diagnostics and choose different data; their traversal/summary is never inherited by Assistant. Changes to Task/Skill/catalog and native effect validation retain their independent contracts.


residentSnapshot() returns the last initialized committed Context without acquiring the transaction slot, restoring persistence or mutating state. Before initialization it returns nil; an in-flight commit leaves the previous committed value readable. Role State reads use their owning Agent’s residentContext() accessor; Agent start() performs the existing initialization through snapshot(). Operational snapshot()/transaction semantics remain unchanged, including validation, recovery and explicit persistence failure.

ui.windows reports windowID/title/content/mode/phase and focusedID from the UI owner. Photography and ApplicationControl select it explicitly; BasicInteraction remains unchanged. It contains no capture, media or Task authority.

WebBrowsing/WebDrawing选择ui.web与ui.windows；ui.web 由生产者提供按窗口组织的页面类型与 URL，本地路径保持 unknown。Skill加载改变下一轮读取集合，新增来源无需修改角色路径清单。

AgentStateContext registers scope-aware multimodal readers/reset callbacks alongside ordinary facts. multimodalSnapshot reads only selected sources, checks session generation and enforces 8 KiB/source, 16 KiB facts and five images. snapshot remains a text-only facade. synchronize resets explicit selections when the committed dialog identity changes; Skill visibility does not reset media. Sources own bytes and lifecycle.

The shared Chat projection combines snapshot images with the current input's user message. Source/image metadata and the one-based attachment mapping live in system State; the source snapshot still owns selection and bytes, with no role-specific image-message generation.

Multimodal snapshots retain source-owned private resourceScope bindings and image scopes outside facts JSON. Camera withholds facts/attachments when its window is not visible, but retains its cache until actual closure. Registry aggregation preserves private bindings without interpreting them.

actions.web.screenshot 通过同一多模态注册表读取 Actions.Web 的单槽当前图片；WebBrowsing 显式选择它。来源按调用会话隔离、检查窗口/页面有效性，不提供历史选择；dialog reset 无显式图片选择可清理，来源自行处理窗口和根生命周期。

Feedback evidence retains optional immutable invocation snapshots. Small original function/argument values are encoded inline; large values encode a verified archive reference and byte count. Legacy feedback without a snapshot remains unknown. Context does not infer arguments from a current registry, truncate them after effects, or replay an Action during restoration.
