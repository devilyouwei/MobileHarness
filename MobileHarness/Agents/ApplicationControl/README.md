# ApplicationControl - Application and independent device tasks

## 函数与通信注册清单

✅ 以下为当前实现的完整注册清单。模型权限来源：[配置文件](ApplicationControl.agent.json)；内部权限来源见各行链接。参数后缀 `?` 表示可选，`—` 表示无参数或无 Channel。

模型 Action 通过 Action call 调度；模型 Tool 通过原生函数调用取得结果。InternalAction / InternalTool 是代码固定流程的权限，不会自动进入模型函数目录。同一函数跨 Agent 注册，或在同一 Agent 同时提供模型入口与内部入口，属于授权复用；模型 Action 和模型 Tool 不重复注册同一路径。

### 模型可调用函数

| 类型 | 模型名称 | 函数路径 | 默认 Channel | 参数 / 约束 | 函数说明 |
| --- | --- | --- | --- | --- | --- |
| Action | `openPage` | `UI.Navigation.open` | Display | `destination: string` — home, settings, language, recognition, synthesis, vision, bluetooth or history. | On a conversational request, open the requested application page through authorized UI presentation. Touch navigation is local and does not call this Agent. |
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
| Tool | `ModelResources.snapshot` | `System.ModelResources.snapshotResources` | — | — | Read current shared model resource inventory, installed groups and progress. Does not download, remove or switch a model. |
| Tool | `Provider.readSettings` | `System.Provider.readSettings` | — | — | Read confirmed cloud-enabled status and selected cloud model. Contains no URL/key. Does not probe provider availability or change configuration. |
| Tool | `Bluetooth.readStatus` | `System.Device.readStatus` | — | — | Read current Bluetooth power/connection and discovered device IDs. Does not scan or move a robot. |
| Tool | `Bluetooth.control` | `System.Device.control` | — | `operation: string` — {"enum": ["scan", "stopScan", "connect", "reconnect", "disconnect", "forget", "refresh"]}<br>`id?: string` | Submit an explicit Bluetooth connection/discovery command. Accepted is not connected or physically completed. Read status to confirm actual state. |
| Tool | `App.readEnvironment` | `System.Device.readEnvironment` | — | — | Read latest sequenced scene, navigation and device capability facts admitted by the root Agent. Facts are observations, not proof of physical completion. |
| Tool | `ModelResources.download` | `System.ModelResources.download` | — | `id: string`<br>`endpoint: string`<br>`allowsCellular: string` — {"enum": ["true", "false"]} | Admit a model download using an explicit source. Admission does not mean installed; read the shared inventory for progress. |
| Tool | `ModelResources.cancel` | `System.ModelResources.cancel` | — | `id: string` | Cancel and join an admitted model transfer. Failure is returned without replay. |
| Action（动态通信目录） | `send` | `Agent.Communication.send` | Communication | `target`, `kind`, `content`, `taskID?`, `artifactID?` | 授权目标：assistant；kind：progress, result。request 创建任务时不传 taskID，其他类型要求已有 taskID。由 [AgentCommunicationAdapter.swift](../Support/Chat/AgentCommunicationAdapter.swift) 根据 task.* send 权限生成；不是 Tool。 |


### 代码固定流程的内部函数

| 类型 | 函数路径 | Channel | 参数 | 函数说明 | 注册来源 |
| --- | --- | --- | --- | --- | --- |
| InternalAction | `UI.Caption.beginReplyTurn` | Display | — | 开始本轮回复字幕展示。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalAction | `Speech.Playback.speak` | Speech | `audioID` | 播放当前真实输出 Agent 所有的 audioID；进入串行 Speech Channel，不因子 Agent 回复而取消父 Agent 播放。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalAction | `UI.Caption.print` | Display | `text` | 将回复文本输出到字幕；保持真实输出 Agent 和任务归属。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalTool | `System.Device.control` | — | `operation`, `id?`, `value?`, `action?`, `fence?` | 执行可信设备/设置指令，包括连接和设置页机械臂测试。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.Navigation.open` | — | `destination` | 执行后端发起的页面导航；普通点击导航仍由前端直接处理。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.download` | — | `id`, `endpoint`, `allowsCellular` | 启动指定来源的模型下载；启动接纳不等于安装完成。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.cancel` | — | `id` | 取消并收束指定资源下载。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.remove` | — | `id` | 删除指定已安装模型资源。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.Provider.restoreSettings` | — | `requestID` | 通过私有 requestID 恢复 Provider 设置，不在 Signal 中传递明文凭据。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.Provider.saveSettings` | — | `requestID` | 通过私有 requestID 保存已校验的 Provider 设置。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.ResourcePresentation.showProviderResult` | — | `requestID`, `failureCode?` | 展示 Provider 操作结果或 failureCode。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.Provider.discoverModels` | — | `requestID` | 通过私有 requestID 发起 Provider 模型发现。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.snapshotResources` | — | — | 读取模型资源库存及进度快照。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.ResourcePresentation.showResources` | — | `generation` | 按 generation 展示资源快照。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.ResourcePresentation.showResourceFailure` | — | `generation`, `message` | 按 generation 展示资源读取失败。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.ResourcePresentation.showResourceOperationFailure` | — | `message` | 展示资源操作失败。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.ResourcePresentation.showResourcePreferenceFailure` | — | `reason`, `message` | 展示资源偏好/选择验证失败。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.restoreSource` | — | — | 恢复已保存的模型来源及语音选择。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.saveSource` | — | `endpoint`, `allowsCellular`, `recognition`, `synthesis` | 保存下载来源、蜂窝网络偏好和语音模型选择。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.configureSpeech` | — | `recognition`, `synthesis` | 应用识别与合成模型选择。 | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |


### 通信输出权限

这些是 CommunicationAction 的授权契约，不是额外的原生 Tool。publish 单向广播，不等待接收方回包，不因接收方拒绝/错误影响发送方；send 返回接纳回执，接纳与任务完成分别记录。模型 send 仅暴露上述 task.* 权限；语音合成、取消及事实广播由代码固定流程发出。

| 方式 | 契约 | 目标 | 用途 |
| --- | --- | --- | --- |
| publish | `interaction.replyActivity` | 订阅者 | 广播回复活动及任务占用事实，供聆听策略判断。 |
| send | `task.progress` | `assistant` | 报告任务进度或等待用户信息，保持任务开放。 |
| send | `task.result` | `assistant` | 报告任务最终成功、失败或取消。 |
| send | `speech.synthesize` | `speechSynthesis` | 提交文本合成请求；原输出 Agent 负责播放。 |
| send | `speech.cancel` | `speechSynthesis` | 取消对应合成工作。 |



Purpose: Application and independent device tasks. Design goal: role-owned decisions with explicit permissions and shared, bounded execution mechanics.

ApplicationControl owns resource/configuration/provider/navigation/Bluetooth connection workflows and fixed settings device transactions and environment facts. It combines natural-language tasks with the existing deterministic transaction policy. Photography camera decisions and permissions belong to Photographer.

| File | Responsibility |
| --- | --- |
| ApplicationControlAgent.swift | Fixed staged transactions, correlated calls and independent Chat composition/output relay. |
| ApplicationControlProcessing.swift | Structured state/preprocessing/builder, internal fixed grants and resource result policy. |
| ApplicationControl.agent.json | Resource/provider/navigation/Bluetooth connection and Settings Robot model calls, reply and task/synthesis communication. |

Typed UI data/device intent arrives through direct user-source subscriptions; conversational delegation remains TaskRequest; runtime environment/failure facts remain direct typed system inputs. New natural tasks use an injected per-decision Chat binding, pinned across continuations. JSON owns model exposure; code owns fixed grants. Both use registered canonical Actions. Configuration commits, actual device results and delivery receipts remain distinct; partial failure cannot claim rollback or replay.

Context: independent conversation/task views, pending calls32 and environment categories32. One staged fixed input commits its state before publishing outputs. Preference/provider/presentation steps preserve existing sequencing and bounded request transport. TaskCancel removes only the matching transaction; other tasks remain isolated.

Upstream: Assistant task Signals and App system facts. Downstream: registered resource/provider/navigation/device/reply Actions, task/synthesis communication, injected ChatCapability/repository. App resource policy retains fixed device transaction authority for this real role and permits it to preempt Photographer only through joined native/resource cleanup.

## Processing and state

Implemented: admitted Signal -> role preprocessing -> atomic structured context -> selected immutable batch -> role/context adapter -> fixed decision or shared one-round Chat worker -> Action output -> directed runtime feedback. Model XML communication and fixed framework communication use the same CommunicationAction transport. Receipt means admission, not task completion. Only explicit TaskProgress/TaskResult update a requester.

The role owns its context repository and schema; it does not read a parent's private inference history. Chat evidence preserves actual requests, native call/result pairs, usage and failures. Media bytes stay in bounded runtime stores; context keeps authorized references. Legacy business documents without Chat fields migrate once; partial/null/unsupported Chat fields fail. Write failure prevents dependent output. Restart interrupts unfinished work and never replays effects.

Model decisions have one worker, FIFO inbox32 plus one reserved continuation, output256, four requests, sixteen native calls, cumulative execution30 seconds and queue expiry60 seconds. Fixed intent admission does not wait for model loading or inference. Task views retain256 identities, at most32 live; terminal retention may retire old identities. Communication has16 pending outputs/four runtime deliveries. All overflow rejects explicitly.

Pause cancels/joins inference and records cancelled decisions; resume admits future work without replay. Stop joins the Chat worker and relay. App owns registration/consumption independently of UI pages and microphone capture. Cancellation/target loss ends the correlated task; partial native effects remain actual facts. Existing platform safety is independent of Agent inference.

## Development standard

Use the same source template: Interface; State and dependencies; Registration; Lifecycle; Input processing; Output; Context; Observability. Keep schemas, preprocessing, builders and permissions in the role directory. Register every emitted function and communication contract explicitly; fixed and model calls reuse the canonical Action implementation. Core has no role/model/storage dependencies; Support adapts shared capabilities, not domain effects.

Automated tests and builds are recorded in [validation](../../../docs/Validation-History.md). Real model, native UI, acoustic and physical-device acceptance remain outstanding. See [ADR0188](../../../docs/adr/0188-specialist-task-ownership.md).

✅ Implemented: business admission failures on validated external Signals emit correlated agent.error through the normal output stream before rejection. Authentication failures do not emit effects. This is an independent error observation, not a publication receipt; waiting UI operations consume it without waiting for the result watchdog.


✅ Production Chat processing publishes revisioned interaction.replyActivity occupancy through the output stream. This reports only interactive reply work, not deterministic/background busy, and grants no listening Action or microphone ownership. SpeechPerception consumes the full bounded snapshot.



✅ Fixed state/context admission uses AgentAdmissionGate with32 FIFO waiters. Concurrent actor entry waits for the current short transaction; only an actually full waiting queue rejects capacityExceeded. Cancellation removes waiting admission; stop closes it. Model inference and device work never hold this gate, and existing business-call limits remain unchanged.



✅ Shared Action registration: Action implementations support many-to-many Agent registration. ApplicationControl registers the 11 Robot Actions for Settings command tests. Assistant retains basic interaction registration; Photographer retains camera-only model permissions. Each role calls canonical functions under its own identity; no inter-Agent delegation is needed to reuse an Action.

✅ Frontend/backend separation: ApplicationControl subscribes directly to user-source device/provider/resource data contracts. Fixed requests update business context without creating delegated tasks. Conversational tasks and registered UI openPage Actions remain separately authorized.


✅ Reply/lifecycle regression correction: caption focus is presentation only and cannot cancel an authorized queued/playing reply from another Agent. Playback checks active session and explicit task cancellation, retaining Gateway owner/task/function authorization and the shared serialized Speech Channel. ApplicationControl accepts environment facts and correlated feedback while paused; fresh business commands still require running. Assistant delegation prompts emit send without redundant spoken acknowledgments and leave specialist speech to its executor. Scope/result delivery failures retain actual evidence; no silent error suppression or action replay is added. Add owner-switch playback admission and paused environment regressions.

✅ Publication audit correction: publish validates its own payload/source and submits bounded one-way work, never awaiting subscriber or App observer completion and never returning recipient errors. Observer work shares bounded Gateway publication lifetime; overflow is diagnostic loss without publisher acknowledgment. Environment facts bypass request/result waiters and emit no completion acknowledgment; ApplicationControl errors still flow through its independent output consumer. Directed send retains correlated admission receipt (not task completion). Explicit UI data-operation result waits remain business completion contracts, not publish receipts.

✅ Resource-fact extension of the same audit: model-resource observations are also one-way facts. Their registered presentation functions and runtime feedback execute under the root-owned ApplicationControl consumer independently of request slots. Sampling never retries because the subscriber rejected or its presentation failed. Tests await observable business state, not a publication receipt.


✅ Send Action-only audit (2026-10-10): remove automatic Agent.send native Tool declarations and the per-role exposesNativeCommunicationTools switch. Every role keeps authorized send Action declarations, target/kind/parameter documentation and receipt/task ownership contracts. Existing business Tools and historical native call/result evidence remain unchanged. Reject an explicit communication Tool registration instead of silently exposing it. Regression tests check all seven effective model catalogs and task request/progress/input/result flows using Action-call send, including roles with business Tools.


✅ Duplicate model registration audit (2026-10-10): Remove model Tool App.openPage (UI.Navigation.open), retaining its scheduled openPage Action and code-owned fixed navigation InternalTool. Other model business Tools remain declared. Model exposure must not present one path as both Action and Tool.

The effective model catalog now has7 business Tools. Code-owned fixed navigation remains an InternalTool, so direct UI navigation transactions keep their existing feedback/authority without offering the model two protocols for the same function.
