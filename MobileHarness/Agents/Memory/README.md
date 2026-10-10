# Memory - History tasks and committed evidence

## 函数与通信注册清单

✅ 以下为当前实现的完整注册清单。模型权限来源：[配置文件](Memory.agent.json)；内部权限来源见各行链接。参数后缀 `?` 表示可选，`—` 表示无参数或无 Channel。

模型 Action 通过 Action call 调度；模型 Tool 通过原生函数调用取得结果。InternalAction / InternalTool 是代码固定流程的权限，不会自动进入模型函数目录。同一函数跨 Agent 注册，或在同一 Agent 同时提供模型入口与内部入口，属于授权复用；模型 Action 和模型 Tool 不重复注册同一路径。

### 模型可调用函数

| 类型 | 模型名称 | 函数路径 | 默认 Channel | 参数 / 约束 | 函数说明 |
| --- | --- | --- | --- | --- | --- |
| Tool | `History.list` | `History.Conversation.list` | — | `offset: string`<br>`limit: string` | List current and archived conversations, current first then newest archives. Returns paged JSON metadata with IDs and explicitly truncated title/input previews. Start at offset 0; use nextOffset for more. |
| Tool | `History.read` | `History.Conversation.read` | — | `id: string`<br>`offset: string`<br>`limit: string` | Read a conversation by an ID returned by History.list. Turns are oldest first. Returns paged JSON with bounded user/response previews and truncation flags, not complete text; never replays behavior. Start at offset 0. |
| Action（动态通信目录） | `send` | `Agent.Communication.send` | Communication | `target`, `kind`, `content`, `taskID?`, `artifactID?` | 授权目标：assistant；kind：progress, result。request 创建任务时不传 taskID，其他类型要求已有 taskID。由 [AgentCommunicationAdapter.swift](../Support/Chat/AgentCommunicationAdapter.swift) 根据 task.* send 权限生成；不是 Tool。 |


### 代码固定流程的内部函数

| 类型 | 函数路径 | Channel | 参数 | 函数说明 | 注册来源 |
| --- | --- | --- | --- | --- | --- |
| InternalAction | `UI.Caption.beginReplyTurn` | Display | — | 开始本轮回复字幕展示。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalAction | `Speech.Playback.speak` | Speech | `audioID` | 播放当前真实输出 Agent 所有的 audioID；进入串行 Speech Channel，不因子 Agent 回复而取消父 Agent 播放。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalAction | `UI.Caption.print` | Display | `text` | 将回复文本输出到字幕；保持真实输出 Agent 和任务归属。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalTool | `History.Conversation.startNew` | — | — | 归档当前对话并开始新的当前对话。 | [MemoryHistoryWorkflow.swift](MemoryHistoryWorkflow.swift) |
| InternalTool | `History.Conversation.summarize` | — | `id` | 为指定对话生成摘要标题，参与归档流程。 | [MemoryHistoryWorkflow.swift](MemoryHistoryWorkflow.swift) |
| InternalTool | `History.Conversation.delete` | — | `id` | 处理可信 UI 确认的历史删除；不允许模型伪造删除确认。 | [MemoryHistoryWorkflow.swift](MemoryHistoryWorkflow.swift) |
| InternalTool | `UI.HistoryPresentation.showHistory` | — | — | 刷新对话历史的 UI 投影。 | [MemoryHistoryWorkflow.swift](MemoryHistoryWorkflow.swift) |


### 通信输出权限

这些是 CommunicationAction 的授权契约，不是额外的原生 Tool。publish 单向广播，不等待接收方回包，不因接收方拒绝/错误影响发送方；send 返回接纳回执，接纳与任务完成分别记录。模型 send 仅暴露上述 task.* 权限；语音合成、取消及事实广播由代码固定流程发出。

| 方式 | 契约 | 目标 | 用途 |
| --- | --- | --- | --- |
| publish | `interaction.replyActivity` | 订阅者 | 广播回复活动及任务占用事实，供聆听策略判断。 |
| send | `task.progress` | `assistant` | 报告任务进度或等待用户信息，保持任务开放。 |
| send | `task.result` | `assistant` | 报告任务最终成功、失败或取消。 |
| send | `speech.synthesize` | `speechSynthesis` | 提交文本合成请求；原输出 Agent 负责播放。 |
| send | `speech.cancel` | `speechSynthesis` | 取消对应合成工作。 |



Purpose: History tasks and committed evidence. Design goal: role-owned decisions with explicit permissions and shared, bounded execution mechanics.

Memory owns history refresh, confirmed deletion, archive/title sequencing and natural-language history tasks. Fixed workflows retain existing UI confirmation authority; model declarations expose bounded history read/list only. A model cannot manufacture a deletion confirmation.

| File | Responsibility |
| --- | --- |
| MemoryAgent.swift | Deterministic history sequencing, independent Chat composition and output relay. |
| MemoryProcessing.swift | Structured pending calls/private Chat history/task views, role preprocessing and builder. |
| MemoryHistoryWorkflow.swift | Fixed correlated archive/title/delete/presentation state machine; no I/O. |
| ConversationTitleGenerator.swift | Bounded title-only capability computation; no mutations or task transport. |
| Memory.agent.json | History query tools, reply and directed task/synthesis communication. |

Natural TaskRequest admission is separate from inference. Memory waits for an authorized parentCommitted TaskInput after the parent's exact request, native receipts and pair evidence commit; it then starts its own decision. The child receives only explicit task content/references. Typed UI transactions bypass model loading and use the same canonical History/UI functions. Archive commits before title computation; title/presentation failure preserves actual committed data.

Context: independent Chat history, task views, at most one deterministic pending history call. App's history transport allows one page operation and retains8 fixed outputs while independently consuming generated/task communication. Cancellation joins effects and reports a true terminal outcome; it never rolls back committed archive/deletion.

Upstream: Assistant tasks/typed history intent and correlated runtime feedback. Downstream: History and history-presentation Actions, task/synthesis communication, injected ChatCapability/repository. Assistant's user-history projection is accessed only through the authorized canonical History capability.

## Processing and state

Implemented: admitted Signal -> role preprocessing -> atomic structured context -> selected immutable batch -> role/context adapter -> fixed decision or shared one-round Chat worker -> Action output -> directed runtime feedback. Model XML communication and fixed framework communication use the same CommunicationAction transport. Receipt means admission, not task completion. Only explicit TaskProgress/TaskResult update a requester.

The role owns its context repository and schema; it does not read a parent's private inference history. Chat evidence preserves actual requests, native call/result pairs, usage and failures. Media bytes stay in bounded runtime stores; context keeps authorized references. Legacy business documents without Chat fields migrate once; partial/null/unsupported Chat fields fail. Write failure prevents dependent output. Restart interrupts unfinished work and never replays effects.

Model decisions have one worker, FIFO inbox32 plus one reserved continuation, output256, four requests, sixteen native calls, cumulative execution30 seconds and queue expiry60 seconds. Fixed intent admission does not wait for model loading or inference. Task views retain256 identities, at most32 live; terminal retention may retire old identities. Communication has16 pending outputs/four runtime deliveries. All overflow rejects explicitly.

Pause cancels/joins inference and records cancelled decisions; resume admits future work without replay. Stop joins the Chat worker and relay. App owns registration/consumption independently of UI pages and microphone capture. Cancellation/target loss ends the correlated task; partial native effects remain actual facts. Existing platform safety is independent of Agent inference.

## Development standard

Use the same source template: Interface; State and dependencies; Registration; Lifecycle; Input processing; Output; Context; Observability. Keep schemas, preprocessing, builders and permissions in the role directory. Register every emitted function and communication contract explicitly; fixed and model calls reuse the canonical Action implementation. Core has no role/model/storage dependencies; Support adapts shared capabilities, not domain effects.

Automated tests and builds are recorded in [validation](../../../docs/Validation-History.md). Real model, native UI, acoustic and physical-device acceptance remain outstanding. See [ADR0188](../../../docs/adr/0188-specialist-task-ownership.md).


✅ Production Chat processing publishes revisioned interaction.replyActivity occupancy through the output stream. This reports only interactive reply work, not deterministic/background busy, and grants no listening Action or microphone ownership. SpeechPerception consumes the full bounded snapshot.



✅ Fixed state/context admission uses AgentAdmissionGate with32 FIFO waiters. Concurrent actor entry waits for the current short transaction; only an actually full waiting queue rejects capacityExceeded. Cancellation removes waiting admission; stop closes it. Model inference and device work never hold this gate, and existing business-call limits remain unchanged.

✅ Frontend/backend separation: Memory subscribes directly to history.intent from user/runtime. Typed history operations remain deterministic transactions; conversational delegated history tasks retain their independent task/parent-commit protocol.


✅ Send Action-only audit (2026-10-10): remove automatic Agent.send native Tool declarations and the per-role exposesNativeCommunicationTools switch. Every role keeps authorized send Action declarations, target/kind/parameter documentation and receipt/task ownership contracts. Existing business Tools and historical native call/result evidence remain unchanged. Reject an explicit communication Tool registration instead of silently exposing it. Regression tests check all seven effective model catalogs and task request/progress/input/result flows using Action-call send, including roles with business Tools.
