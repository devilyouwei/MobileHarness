# Memory

## 职责与边界

✅ 历史读写、归档、删除及标题生成事务；不生成普通对话。 Agents 管业务策略和上下文，Gateway 管权限/传输，Actions 管函数实现；原生设备与 UI 端口由 App 注入。没有跨 Agent 共享可写聊天历史。

## 文件分工

MemoryAgent.swift 管接纳和事务；MemoryHistoryWorkflow.swift 管固定关联步骤；MemoryProcessing.swift 管状态；ConversationTitleGenerator.swift 仅生成标题。

## 输入、输出与流程

UI 历史事务经固定函数执行；归档提交后才生成标题，失败保留已提交归档。Assistant 的 history-query Skill 使用历史查询原生 Tools。

## Context 与 Builder

调用关联、事务状态；标题请求不写普通历史记录。 状态通过独立 Repository 原子提交；Builder 选择确定版本，不修改已发出的请求。写入失败不产生依赖未提交状态的新调用。

## 生命周期、容量与失败

✅ 已实现（2026-10-13）：MemoryAgent.prepareSignal 明确保留最近 4096 条 Signal 证据及消费批次，最旧证据淘汰计数持久化；已满的有效 context 首次新输入即可收敛。调用关联、任务、历史文档独立保存，证据淘汰不删除聊天或取消已接纳事务；真实写入失败继续传播。

标题独立注入 ChatCapability，抽取最多 32 轮历史，每段 80 Characters，输出最多 64 tokens，30 秒超时。标题必须单行非空、≤80 Characters，拒绝动作和原生调用。 事务/输出消费由 App 根生命周期持有，独立于页面。输出最多 256，状态提交等待最多 32；通信消费者最多 16 待处理、4 并发。超限明确失败。取消加入已接纳工作清理；重启标记未完成任务中断，不重放设备动作。共享 Chat 的输入、调用和执行预算见 [Chat](../Support/Chat/README.md)。

## 函数权限与注册

[Agent.json](../../Resources/Agents/Memory/Agent.json) 声明固定函数；业务模型目录由加载 Skill 决定。实际实现/参数契约以 [owning @Action declarations](../../Actions/README.md) 为准。Internal 固定函数不会自动向模型开放。

本角色没有对话 worker。以下为本角色固定函数声明；实际固定调用由该角色 workflow 注册，不能把固定函数表误认为普通对话目录。

| 类型 / Channel | 别名 | 函数 | 参数 | 说明 |
| --- | --- | --- | --- | --- |
| tool / — | `History.list` | `History.Conversation.list` | offset 必填, limit 必填 | List current and archived conversations, current first then newest archives. Returns paged JSON metadata with IDs and explicitly truncated title/input previews. Start at offset 0; use nextOffset for more. |
| tool / — | `History.read` | `History.Conversation.read` | id 必填, offset 必填, limit 必填 | Read a conversation by an ID returned by History.list. Turns are oldest first. Returns paged JSON with bounded user/response previews and truncation flags, not complete text; never replays behavior. Start at offset 0. |

## 固定内部权限

| Protocol | Canonical function | Channel | Parameters | Registration source |
| --- | --- | --- | --- | --- |
| InternalTool | `History.Conversation.startNew` | — | — | [MemoryHistoryWorkflow.swift](MemoryHistoryWorkflow.swift) |
| InternalTool | `History.Conversation.summarize` | — | `id` | [MemoryHistoryWorkflow.swift](MemoryHistoryWorkflow.swift) |
| InternalTool | `History.Conversation.delete` | — | `id` | [MemoryHistoryWorkflow.swift](MemoryHistoryWorkflow.swift) |
| InternalTool | `UI.HistoryPresentation.showHistory` | — | — | [MemoryHistoryWorkflow.swift](MemoryHistoryWorkflow.swift) |

### Declared input schemas

| Contract | Version | Kind |
| --- | --- | --- |
| `history.intent` | 1 | `observation` |
| `tool.result` | 1 | `toolResult` |
| `task.request` | 1 | `observation` |
| `task.input` | 1 | `observation` |
| `task.progress` | 1 | `observation` |
| `task.result` | 1 | `observation` |
| `task.cancel` | 1 | `observation` |
| `action.result` | 1 | `actionResult` |
| `generation.round.result` | 1 | `roundResult` |
| `communication.receipt` | 1 | `communicationReceipt` |
| `user.text` | 1 | `text` |

Directed input schemas and static subscriptions are distinct; admission also validates the runtime sender and scope.

## 状态与验收

✅ 动态 Skill/确定性职责拆分已实现。❌ 摄影、保存、尾音、语音竞争及模式切换的真机验收仍需单独进行。

✅ 收紧资源中的普通文本/模型反馈和语音对话通信，保留确定性协议。

## 输入与通信授权

| 输入契约 | 类型 |
| --- | --- |
| `history.intent` | observation |
| `tool.result` | toolResult |
| `task.request` | observation |
| `task.input` | observation |
| `task.progress` | observation |
| `task.result` | observation |
| `task.cancel` | observation |
| `communication.receipt` | communicationReceipt |

| 方式 | 契约 | 目标/来源 |
| --- | --- | --- |
| send Action | `task.progress` | `assistant` |
| send Action | `task.result` | `assistant` |
| subscribe | `history.intent` | `runtime` |
| subscribe | `history.intent` | `user` |


## 固定函数与 Skill

✅ 资源不再包含 Permissions.json，Agent.json 的 baseSkills 引用 Skill，Skill.json 声明函数。业务模型函数由已加载 Skill 提供；固定调用与模型轮次分别验证，详见 [资源规范](../../Resources/Agents/README.md)。

## Agent → Skill → Function registration

✅ Implemented: Agent.json references baseSkills; Skill.json alone registers model Actions/Tools. BasicSkill owns task orchestration and environment reading; ExpressionInteraction owns expression Actions. Role instructions retain identity/responsibility/style. Business roles reuse existing Skills; internal trusted bindings remain separate. Fixed transaction/task snapshots remain authoritative.

角色基础函数目录由资源中的 baseSkills（history-query）组合；上表供函数 review 使用，不是 Agent.json 中的另一份注册。函数说明属于实现，流程教学属于 Skill。


## Cloud title thinking policy

✅ Implemented: title generation retains the existing two-message request, 64-token budget, 30-second joined deadline and explicit rejection of incomplete/empty titles. The shared [cloud request encoder](../../ModelKit/Language/LLM/OpenAI/README.md#non-thinking-request-policy) disables provider thinking before execution, preventing supported models from spending the title budget on reasoning. Memory does not own vendor-specific fields or retry with a larger budget. Existing archive/title persistence and failure presentation remain unchanged; opt-in synthetic provider evidence is recorded separately from native UI/device acceptance.



## SQLite records and runtime identity

✅ Implemented: technical identities are opaque UUID strings; committed business entities use dialog/message/task/media/device SQLite IDs. Consumers use Storage repositories while preserving ownership, cancellation and independent foundation boundaries. Complete messages, including each ReACT message, persist at termination; delta fragments do not persist. The custom allocator and replaced file/index implementation are removed. See the project SQLite business-record plan.
