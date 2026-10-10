# Assistant - Default user entry and delegation

## 函数与通信注册清单

✅ 以下为当前实现的完整注册清单。模型权限来源：[配置文件](Assistant.agent.json)；内部权限来源见各行链接。参数后缀 `?` 表示可选，`—` 表示无参数或无 Channel。

模型 Action 通过 Action call 调度；模型 Tool 通过原生函数调用取得结果。InternalAction / InternalTool 是代码固定流程的权限，不会自动进入模型函数目录。同一函数跨 Agent 注册，或在同一 Agent 同时提供模型入口与内部入口，属于授权复用；模型 Action 和模型 Tool 不重复注册同一路径。

### 模型可调用函数

| 类型 | 模型名称 | 函数路径 | 默认 Channel | 参数 / 约束 | 函数说明 |
| --- | --- | --- | --- | --- | --- |
| Action | `express` | `UI.Expression.express` | Display | `emotion: string` — Exactly one of: smile, happy, laugh, thinking, surprised, sad, love, angry, scared, playful. clear is invalid; use setExpression for persistent state or clearing. | Perform one eye expression, awaiting its transition and return to the current base expression. Each call is a fresh performance. Does not change captions or speech. |
| Action | `setExpression` | `UI.Expression.setExpression` | Display | `emotion: string` — Exactly one of: clear, smile, happy, laugh, thinking, surprised, sad, love, angry, scared, playful. clear resets the base to neutral. | Set the persistent base eye expression until replaced, cleared or reset on new user speech. Completes on state acceptance, not animation completion. Repeating the same emotion is idempotent. |
| Action | `shakeBase` | `NexArm.Motion.shakeBase` | Robot | `cycles: integer` — Integer 1 through 3 only.<br>`speed?: integer` — Native motor speed, 1–1400; default1400.<br>`acceleration?: integer` — Native acceleration register value, 1–254; default30. | Perform the requested finite gesture using motors1–5, starting and ending at their home; never command or wait for the gripper. Accept optional native speed1–1400 and acceleration1–254. Stable arrival advances immediately. Stable off-target positions, send errors and missing feedback end only affected atomic steps and are collected in the final report; subsequent composition steps and Channel actions continue. Unavailable-device steps fail without blind writes, queries or replay. Explicit cancellation stops remaining work. Use only on user request with a connected arm and clear space. |
| Action | `waveWrist` | `NexArm.Gesture.waveWrist` | Robot | `count: integer` — Integer 1 through 3. No default.<br>`speed?: integer` — Native motor speed, 1–1400; default1400.<br>`acceleration?: integer` — Native acceleration register value, 1–254; default30. | Perform the requested finite gesture using motors1–5, starting and ending at their home; never command or wait for the gripper. Accept optional native speed1–1400 and acceleration1–254. Stable arrival advances immediately. Stable off-target positions, send errors and missing feedback end only affected atomic steps and are collected in the final report; subsequent composition steps and Channel actions continue. Unavailable-device steps fail without blind writes, queries or replay. Explicit cancellation stops remaining work. Use only on user request with a connected arm and clear space. |
| Action | `tiltWrist` | `NexArm.Gesture.tiltWrist` | Robot | `direction: string` — Exactly left or right.<br>`speed?: integer` — Native motor speed, 1–1400; default1400.<br>`acceleration?: integer` — Native acceleration register value, 1–254; default30. | Perform the requested finite gesture using motors1–5, starting and ending at their home; never command or wait for the gripper. Accept optional native speed1–1400 and acceleration1–254. Stable arrival advances immediately. Stable off-target positions, send errors and missing feedback end only affected atomic steps and are collected in the final report; subsequent composition steps and Channel actions continue. Unavailable-device steps fail without blind writes, queries or replay. Explicit cancellation stops remaining work. Use only on user request with a connected arm and clear space. |
| Action | `lookAround` | `NexArm.Gesture.lookAround` | Robot | `cycles: integer` — Integer 1 through 3. No default.<br>`speed?: integer` — Native motor speed, 1–1400; default1400.<br>`acceleration?: integer` — Native acceleration register value, 1–254; default30. | Perform the requested finite gesture using motors1–5, starting and ending at their home; never command or wait for the gripper. Accept optional native speed1–1400 and acceleration1–254. Stable arrival advances immediately. Stable off-target positions, send errors and missing feedback end only affected atomic steps and are collected in the final report; subsequent composition steps and Channel actions continue. Unavailable-device steps fail without blind writes, queries or replay. Explicit cancellation stops remaining work. Use only on user request with a connected arm and clear space. |
| Action | `celebrate` | `NexArm.Gesture.celebrate` | Robot | `cycles: integer` — Integer 1 through 3. No default.<br>`speed?: integer` — Native motor speed, 1–1400; default1400.<br>`acceleration?: integer` — Native acceleration register value, 1–254; default30. | Perform the requested finite gesture using motors1–5, starting and ending at their home; never command or wait for the gripper. Accept optional native speed1–1400 and acceleration1–254. Stable arrival advances immediately. Stable off-target positions, send errors and missing feedback end only affected atomic steps and are collected in the final report; subsequent composition steps and Channel actions continue. Unavailable-device steps fail without blind writes, queries or replay. Explicit cancellation stops remaining work. Use only on user request with a connected arm and clear space. |
| Action | `dance` | `NexArm.Gesture.dance` | Robot | `cycles: integer` — Integer 1 through 3. No default.<br>`speed?: integer` — Native motor speed, 1–1400; default1400.<br>`acceleration?: integer` — Native acceleration register value, 1–254; default30. | Perform the requested finite gesture using motors1–5, starting and ending at their home; never command or wait for the gripper. Accept optional native speed1–1400 and acceleration1–254. Stable arrival advances immediately. Stable off-target positions, send errors and missing feedback end only affected atomic steps and are collected in the final report; subsequent composition steps and Channel actions continue. Unavailable-device steps fail without blind writes, queries or replay. Explicit cancellation stops remaining work. Use only on user request with a connected arm and clear space. |
| Action | `nodHead` | `NexArm.Gesture.nodHead` | Robot | `cycles: integer` — Integer 1 through 3 only; no default.<br>`speed?: integer` — Native motor speed, 1–1400; default1400.<br>`acceleration?: integer` — Native acceleration register value, 1–254; default30. | Compose home, sweeps and return using only motor4. Leave all other motors untouched. Accept optional native speed1–1400 and acceleration1–254. Stable arrival advances immediately. Stable off-target positions, send errors and missing feedback end only affected atomic steps and are collected in the final report; subsequent composition steps and Channel actions continue. Unavailable-device steps fail without blind writes, queries or replay. Explicit cancellation stops remaining work. Use only on user request with a connected arm and clear space. |
| Action | `shakeHead` | `NexArm.Gesture.shakeHead` | Robot | `cycles: integer` — Integer 1 through 3 only; no default.<br>`speed?: integer` — Native motor speed, 1–1400; default1400.<br>`acceleration?: integer` — Native acceleration register value, 1–254; default30. | Compose home, sweeps and return using only motor5. Leave all other motors untouched. Accept optional native speed1–1400 and acceleration1–254. Stable arrival advances immediately. Stable off-target positions, send errors and missing feedback end only affected atomic steps and are collected in the final report; subsequent composition steps and Channel actions continue. Unavailable-device steps fail without blind writes, queries or replay. Explicit cancellation stops remaining work. Use only on user request with a connected arm and clear space. |
| Action | `resetArm` | `NexArm.Motion.reset` | Robot | `speed?: integer` — Native motor speed, 1–1400; default1400.<br>`acceleration?: integer` — Native acceleration register value, 1–254; default30. | Reset motors1–5 only; do not command or wait for the gripper. Accept optional native speed1–1400 and acceleration1–254. Stable arrival advances immediately. Stable off-target positions, send errors and missing feedback end only affected atomic steps and are collected in the final report; subsequent composition steps and Channel actions continue. Unavailable-device steps fail without blind writes, queries or replay. Explicit cancellation stops remaining work. Use only on user request with a connected arm and clear space. |
| Action | `moveMotor` | `NexArm.Motion.moveMotor` | Robot | `motor: integer` — Motor ID1–6. Reset requires a configured home; current arm homes cover1–5.<br>`target: integer` — Native encoder target, restricted to configured motor limits.<br>`speed?: integer` — Native speed1–1400, default1400.<br>`acceleration?: integer` — Native acceleration1–254, default30. | Move only the explicitly selected motor to its native encoder target. Accept optional native speed1–1400 and acceleration1–254. Stable arrival advances immediately. Stable off-target positions, send errors and missing feedback end only affected atomic steps and are collected in the final report; subsequent composition steps and Channel actions continue. Unavailable-device steps fail without blind writes, queries or replay. Explicit cancellation stops remaining work. Use only on user request with a connected arm and clear space. |
| Action | `resetMotor` | `NexArm.Motion.resetMotor` | Robot | `motor: integer` — Motor ID1–6. Reset requires a configured home; current arm homes cover1–5.<br>`speed?: integer` — Native speed1–1400, default1400.<br>`acceleration?: integer` — Native acceleration1–254, default30. | Reset only the selected motor to its configured home; motor6 requires an explicitly configured home. Accept optional native speed1–1400 and acceleration1–254. Stable arrival advances immediately. Stable off-target positions, send errors and missing feedback end only affected atomic steps and are collected in the final report; subsequent composition steps and Channel actions continue. Unavailable-device steps fail without blind writes, queries or replay. Explicit cancellation stops remaining work. Use only on user request with a connected arm and clear space. |
| Action | `readEnvironment` | `System.Device.readEnvironment` | System | — | Read the latest admitted scene, navigation and device capability facts only when needed and absent from context. These are observations, not proof of physical completion. Wait for the result before deciding dependent actions. |
| Action（动态通信目录） | `send` | `Agent.Communication.send` | Communication | `target`, `kind`, `content`, `taskID?`, `artifactID?` | 授权目标：applicationControl, memory, photographer；kind：cancel, input, request。request 创建任务时不传 taskID，其他类型要求已有 taskID。由 [AgentCommunicationAdapter.swift](../Support/Chat/AgentCommunicationAdapter.swift) 根据 task.* send 权限生成；不是 Tool。 |


### 代码固定流程的内部函数

| 类型 | 函数路径 | Channel | 参数 | 函数说明 | 注册来源 |
| --- | --- | --- | --- | --- | --- |
| InternalAction | `UI.Caption.beginReplyTurn` | Display | — | 开始本轮回复字幕展示。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalAction | `Speech.Playback.speak` | Speech | `audioID` | 播放当前真实输出 Agent 所有的 audioID；进入串行 Speech Channel，不因子 Agent 回复而取消父 Agent 播放。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalAction | `UI.Caption.print` | Display | `text` | 将回复文本输出到字幕；保持真实输出 Agent 和任务归属。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |


### 通信输出权限

这些是 CommunicationAction 的授权契约，不是额外的原生 Tool。publish 单向广播，不等待接收方回包，不因接收方拒绝/错误影响发送方；send 返回接纳回执，接纳与任务完成分别记录。模型 send 仅暴露上述 task.* 权限；语音合成、取消及事实广播由代码固定流程发出。

| 方式 | 契约 | 目标 | 用途 |
| --- | --- | --- | --- |
| publish | `interaction.replyActivity` | 订阅者 | 广播回复活动及任务占用事实，供聆听策略判断。 |
| send | `speech.synthesize` | `speechSynthesis` | 提交文本合成请求；原输出 Agent 负责播放。 |
| send | `speech.cancel` | `speechSynthesis` | 取消对应合成工作。 |
| send | `task.request` | `photographer` | 委派新的子任务。 |
| send | `task.input` | `photographer` | 向已存在的任务补充输入。 |
| send | `task.cancel` | `photographer` | 请求取消指定任务；接纳不代表设备已经停止。 |
| send | `task.request` | `memory` | 委派新的子任务。 |
| send | `task.input` | `memory` | 向已存在的任务补充输入。 |
| send | `task.cancel` | `memory` | 请求取消指定任务；接纳不代表设备已经停止。 |
| send | `task.request` | `applicationControl` | 委派新的子任务。 |
| send | `task.input` | `applicationControl` | 向已存在的任务补充输入。 |
| send | `task.cancel` | `applicationControl` | 请求取消指定任务；接纳不代表设备已经停止。 |



Purpose: Default user entry and delegation. Design goal: role-owned decisions with explicit permissions and shared, bounded execution mechanics.

Assistant owns the first user interaction, basic reply/expression and public task coordination. Photographer owns photography; Memory owns history workflows; ApplicationControl owns settings, resources, providers, navigation and independent device control. Assistant has their capability summaries and bounded public task reports, not their private histories.

| File | Responsibility |
| --- | --- |
| AssistantAgent.swift | Canonical entry specializing AgentChatWorker<AssistantContextState>; avoids a second private Chat loop. |
| AssistantProcessing.swift | Structured history/task views, input validation, Action-only model policy and historical context projection. |
| Assistant.agent.json | Display/Speech/Robot/System Actions, read-only environment observation, empty Tool catalog and directed task/synthesis communication grants. Robot gesture/motor Actions execute directly; no camera or history model calls. |

Typed camera/history/settings UI inputs publish directly to their business owner; Assistant does not subscribe to them or create tasks for them. Natural language chooses the authorized XML send Action. Model content cannot construct trusted UI intent, source identity or execution grants.

Assistant maintains one foreground question and FIFO pending questions. Activation sends prepared TaskInput to the child for fixed speech/caption, without an extra model request. A user answer binds the interaction at speech onset (or text admission); TaskInput validates task/session/question/artifact. Stale inputs reject; ambiguity is handled by the main decision. Completed tasks close focus. Parent decision evidence is committed before Memory receives the parentCommitted input.

Context: current/archived conversation projection plus admission sequence and public task views; unique structured repository is the writable truth. Existing import, archive, delete and UI projection remain compatible. Onset bindings are bounded32 with deadlines; input bindings share inbox capacity. Public prompt reports retain all live tasks and eight bounded terminal excerpts, with lifecycle status read from the task registry (including failure/cancellation), separate from waiting-user stage.

Upstream: App user transport and SpeechPerception semantic Signals. Downstream: OutputGateway functions/task/synthesis communication; injected ChatCapability and structured repository. All child execution results stay with the child.

## Processing and state

Implemented: admitted Signal -> role preprocessing -> atomic structured context -> selected immutable batch -> role/context adapter -> fixed decision or shared one-round Chat worker -> Action output -> directed runtime feedback. XML send uses the common CommunicationAction transport. Receipt means admission, not task completion. Only explicit TaskProgress/TaskResult update a requester.

The role owns its context repository and schema; it does not read a parent's private inference history. Chat evidence preserves actual requests, historical native call/result pairs, usage and failures; old native pairs are projected as inert text in new Assistant requests. Media bytes stay in bounded runtime stores; context keeps authorized references. Legacy business documents without Chat fields migrate once; partial/null/unsupported Chat fields fail. Write failure prevents dependent output. Restart interrupts unfinished work and never replays effects.

Model decisions have one worker, FIFO inbox32 plus one reserved continuation, output256, four requests, cumulative execution30 seconds and queue expiry60 seconds. Fixed intent admission does not wait for model loading or inference. Task views retain256 identities, at most32 live; terminal retention may retire old identities. Communication has16 pending outputs/four runtime deliveries. All overflow rejects explicitly.

Pause cancels/joins inference and records cancelled decisions; resume admits future work without replay. Stop joins the Chat worker and relay. App owns registration/consumption independently of UI pages and microphone capture. Cancellation/target loss ends the correlated task; partial native effects remain actual facts. Existing platform safety is independent of Agent inference.

## Development standard

Use the same source template: Interface; State and dependencies; Registration; Lifecycle; Input processing; Output; Context; Observability. Keep schemas, preprocessing, builders and permissions in the role directory. Register every emitted function and communication contract explicitly; fixed and model calls reuse the canonical Action implementation. Core has no role/model/storage dependencies; Support adapts shared capabilities, not domain effects.

Automated tests and builds are recorded in [validation](../../../docs/Validation-History.md). Real model, native UI, acoustic and physical-device acceptance remain outstanding. See [ADR0188](../../../docs/adr/0188-specialist-task-ownership.md).



✅ Implemented: trusted runtime assistant.control publishes to the default Agent through an exact static subscription; session cancellation no longer needs an external directed-send compatibility host.

## Listening policy ownership

✅ Assistant publishes interaction.replyActivity snapshots containing admitted user reply identities and delegated task holds. It has no listening Action permission and does not receive speech.listening. Waiting-user releases delegated holds after runtime.replyFinished; task completion/cancellation releases them through existing task reports. SpeechPerception alone interprets these facts into listening policy.

❌ True-device acoustic echo, tail, route/interruption and native UI acceptance remain pending.

✅ Production Chat workers receive the current configured model label through ApplicationRuntime. New history records use this label; historical missing labels are not fabricated.


✅ Robot Action ownership correction: Assistant.agent.json declares the Robot Channel and 11 existing NexArm gestures/motion Actions alongside reply/expression. Parameters/examples/function addresses are preserved. Ordinary mechanical-arm requests execute under Assistant identity and return results to its context, without delegation.

✅ Frontend/backend separation: Assistant no longer subscribes to camera/history/resource/provider/device UI command contracts and no longer synthesizes tasks for them. Conversational delegation and explicit task follow-up still use authorized communication.


## Responses and Action-only Assistant migration

✅ Implemented: Assistant.agent.json has an empty tools catalog. Add readEnvironment Action on System Channel with observation feedback. Remove static runtimeInfo and /status special handling; plain text /status is ordinary user input. Send is an authorized communication Action only. Historical native calls/results remain stored but are rendered as inert text evidence for new model requests.

✅ Delegation prompt: emit only the authorized send Action; omit spoken acknowledgment, preamble and duplicate explanations. Specialist owns questions and outcome replies. Parent and specialist playback use the shared serialized Speech function without presentation-focus cancellation; permissions and explicit cancellation remain enforced.


✅ Send Action-only audit (2026-10-10): remove automatic Agent.send native Tool declarations and the per-role exposesNativeCommunicationTools switch. Every role keeps authorized send Action declarations, target/kind/parameter documentation and receipt/task ownership contracts. Existing business Tools and historical native call/result evidence remain unchanged. Reject an explicit communication Tool registration instead of silently exposing it. Regression tests check all seven effective model catalogs and task request/progress/input/result flows using Action-call send, including roles with business Tools.
