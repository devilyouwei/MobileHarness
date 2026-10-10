# Photographer - Photography tasks and tracking

## 函数与通信注册清单

✅ 以下为当前实现的完整注册清单。模型权限来源：[配置文件](Photographer.agent.json)；内部权限来源见各行链接。参数后缀 `?` 表示可选，`—` 表示无参数或无 Channel。

模型 Action 通过 Action call 调度；模型 Tool 通过原生函数调用取得结果。InternalAction / InternalTool 是代码固定流程的权限，不会自动进入模型函数目录。同一函数跨 Agent 注册，或在同一 Agent 同时提供模型入口与内部入口，属于授权复用；模型 Action 和模型 Tool 不重复注册同一路径。

### 模型可调用函数

| 类型 | 模型名称 | 函数路径 | 默认 Channel | 参数 / 约束 | 函数说明 |
| --- | --- | --- | --- | --- | --- |
| Action | `flipCamera` | `Camera.Capture.flip` | Camera | `facing: string` — front or back; change only when requested. | Select the requested front or back lens of the enabled foreground camera. Already selecting that lens leaves it unchanged. Fails if disabled, busy or unavailable. Schedule on Camera; successful completion is execution feedback. Do not repeat a successful command to continue reasoning. |
| Action | `closeCamera` | `Camera.Capture.close` | Camera | — | Disable camera preview and vision processing, and wait for capture and vision cleanup. Schedule on Camera; successful completion is execution feedback. Do not repeat a successful command to continue reasoning. |
| Action | `openCamera` | `Camera.Capture.open` | Camera | — | Enable foreground camera preview and vision processing. Requires camera permission and an available camera; completion confirms capture, not pose-model readiness. Schedule on Camera; successful completion is execution feedback. Do not repeat a successful command to continue reasoning. |
| Action | `takePhoto` | `Camera.Capture.takePhoto` | Camera | — | On an explicit user request, take one photo using the current ready foreground camera. Capture, retain private App evidence and show the actual photo; this does not save to the system Photos library. Its execution observation supplies the photo to the next model round for visual understanding. Emit once, then wait for actual image feedback before describing it. Use savePhoto only on an explicit save request. Do not repeat capture merely to continue reasoning. Camera must be enabled and ready. |
| Action | `savePhoto` | `Camera.Capture.savePhoto` | Camera | `photoID: string` — A photoID from actual capture feedback. | On an explicit user request, save the currently displayed captured photo to the system Photos library. Wait for the actual observation before confirming success; permission denial is a failure. Repeated saves of the same displayed photo do not create duplicates. This does not take another photo. |
| Action | `ignorePhoto` | `Camera.Capture.ignorePhoto` | Camera | `photoID: string` — A photoID from actual capture feedback. | On a request to close, dismiss, ignore or discard the displayed photo, hide its thumbnail and preview without exporting to Photos. This does not close the camera, delete an existing album photo, or take another photo. Wait for the actual result before confirming. |
| Action | `retryCamera` | `Camera.Capture.retry` | Camera | — | Explicitly retry a failed foreground camera operation. Wait for execution feedback; do not automatically repeat failed work. |
| Action（动态通信目录） | `send` | `Agent.Communication.send` | Communication | `target`, `kind`, `content`, `taskID?`, `artifactID?` | 授权目标：assistant；kind：progress, result。request 创建任务时不传 taskID，其他类型要求已有 taskID。由 [AgentCommunicationAdapter.swift](../Support/Chat/AgentCommunicationAdapter.swift) 根据 task.* send 权限生成；不是 Tool。 |


### 代码固定流程的内部函数

| 类型 | 函数路径 | Channel | 参数 | 函数说明 | 注册来源 |
| --- | --- | --- | --- | --- | --- |
| InternalAction | `UI.Caption.beginReplyTurn` | Display | — | 开始本轮回复字幕展示。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalAction | `Speech.Playback.speak` | Speech | `audioID` | 播放当前真实输出 Agent 所有的 audioID；进入串行 Speech Channel，不因子 Agent 回复而取消父 Agent 播放。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalAction | `UI.Caption.print` | Display | `text` | 将回复文本输出到字幕；保持真实输出 Agent 和任务归属。 | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalTool | `NexArm.Tracking.aim` | — | `base`, `pitch` | 确定性追踪使用 base/pitch 目标；要求机械臂控制可用和有效的新姿态，不向摄影模型开放机械臂动作。 | [PhotographerAgent.swift](PhotographerAgent.swift) |
| InternalTool | `Camera.Capture.open` | — | — | 固定相机事务：开启摄像头。 | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |
| InternalTool | `Camera.Capture.close` | — | — | 固定相机事务：关闭摄像头并等待清理。 | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |
| InternalTool | `Camera.Capture.flip` | — | `facing` | 固定相机事务：切换到指定 facing。 | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |
| InternalTool | `Camera.Capture.retry` | — | — | 固定相机事务：显式重试失败操作。 | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |
| InternalTool | `Camera.Capture.savePhoto` | — | `photoID?` | 固定相机事务：保存指定或可信 UI 当前选择的照片。 | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |
| InternalTool | `Camera.Capture.ignorePhoto` | — | `photoID?` | 固定相机事务：忽略指定或可信 UI 当前选择的照片。 | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |


模型 savePhoto / ignorePhoto 必须携带任务所属的 photoID；内部固定流程允许省略 photoID，使用可信 UI 当前选择。内部 aim 只供确定性追踪，不扩展摄影模型的机械臂权限。

### 通信输出权限

这些是 CommunicationAction 的授权契约，不是额外的原生 Tool。publish 单向广播，不等待接收方回包，不因接收方拒绝/错误影响发送方；send 返回接纳回执，接纳与任务完成分别记录。模型 send 仅暴露上述 task.* 权限；语音合成、取消及事实广播由代码固定流程发出。

| 方式 | 契约 | 目标 | 用途 |
| --- | --- | --- | --- |
| publish | `interaction.replyActivity` | 订阅者 | 广播回复活动及任务占用事实，供聆听策略判断。 |
| send | `task.progress` | `assistant` | 报告任务进度或等待用户信息，保持任务开放。 |
| send | `task.result` | `assistant` | 报告任务最终成功、失败或取消。 |
| send | `speech.synthesize` | `speechSynthesis` | 提交文本合成请求；原输出 Agent 负责播放。 |
| send | `speech.cancel` | `speechSynthesis` | 取消对应合成工作。 |



Purpose: Photography tasks and tracking. Design goal: role-owned decisions with explicit permissions and shared, bounded execution mechanics.

Photographer owns natural-language photography decisions, capture observation/understanding, save/ignore/reshoot, camera controls and photography tracking. It combines its independent Chat worker with existing deterministic camera and tracking policies.

| File | Responsibility |
| --- | --- |
| PhotographerAgent.swift | Role lifecycle, fixed camera/tracking decisions, independent Chat composition and one output relay. |
| PhotographerProcessing.swift | State/preprocessing/builder, scoped photo observations and artifact validation. |
| PhotographerCameraWorkflow.swift | One correlated fixed camera transaction; no native effects. |
| PhotographerTrackingPolicy.swift | Pose selection, filtering and accepted-target policy; no I/O. |
| Photographer.agent.json | Seven scheduled Camera Actions, private reply grants and directed task/synthesis communication. |

A TaskRequest invokes the injected ChatCapability under the Photographer identity. Capture ActionResult returns only here; after the round barrier, the role resolves its actual capture reference into an image observation. The image reader is injected and validates source/session/producing input. Questions report TaskProgress including exact artifactID; Assistant activates one prepared reply, then forwards the later user input to this same task. Capture and disposition use canonical Camera functions directly, without an Assistant native proxy.

Context: private conversation, camera request/tracking scope, task views and photoID -> producing-input references. Capture metadata32 retires terminal-task references only; active-task references are retained. Task model save/ignore requires a capture recorded in that same task, never a generated/foreign UUID. Trusted UI disposition retains explicit user-selected image handling.

Fixed camera commands have one slot; tracking has one attached perception scope and rejects stale/foreign poses. Output capacity defaults256 and can be explicitly bounded for isolated hosts; overflow does not advance an accepted target. Native camera/album/resource safety belongs to App/PlatformKit. No raw JPEG/frame persists in Agent context.

Upstream: Assistant task Signals and VisionPerception poses. Downstream: camera/reply Actions, the internal tracking Tool and task/synthesis communication; injected ChatCapability/image reader/repository.

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


✅ Robot Action ownership correction: Robot Channel/model NexArm motion registrations are removed. Retain camera/capture/save/ignore and the code-owned internal NexArm.Tracking.aim used only by deterministic photographic tracking. No model gesture/motor-move permissions remain.

✅ Device regression fix: Photographer prompts require one capture after successful preparation, no unrequested/repeated lens switches, and explicit task.progress with exact photo/task identity for save/ignore questions. A question must not be reported as completed. Photo observations include a concrete authorized progress example; no automatic intent guessing or global photo ownership is introduced.

✅ Camera model exposure: Photographer declares openCamera/closeCamera/flipCamera/retryCamera alongside takePhoto/savePhoto/ignorePhoto as scheduled Camera Actions; no camera native Tool is exposed to the model. Host binds the canonical camera functions to both protocols only for explicit fixed UI transaction reuse. Model camera Actions keep observed owner-directed results and same-Channel ordering/wait groups.

✅ Frontend/backend separation: Photographer subscribes directly to user/runtime photography.camera data commands. Fixed UI camera operations create no Assistant tasks; conversational photography still uses task scopes, observed camera Actions and same-task follow-up.


✅ Camera perception/context change (2026-10-10): PhotographerProcessing adds CameraStateObservation storage, revision/source/session validation and a pure model-context projection of camera facts and current photography phase. PhotographerAgent consumes passive state while running/paused without Chat admission or output. Recovered snapshots are cleared; older revisions within the root session reject without mutation. Task phase projects existing work, task views and task-owned capture references (preparing, awaitingFeedback, reviewingPhoto, waitingUser, cancelling and terminal states), rather than maintaining duplicate task state. Model context is rebuilt before every provider request; unknown camera state remains explicit.

Camera observations retain one latest snapshot (2048-byte contract,512-byte native failure text), not per-sample history. State observation is accepted while paused; it does not queue model work. App samples foreground changes every100ms, so the model sees latest admitted facts, not a synchronous native readiness guarantee. Missing/recovered state is unknown, and Actions retain native validation. UDP-like publication loss is not acknowledged or retried because of receiver rejection; subsequent changed snapshots may update state. ❌ Native UI/capture/save/cancellation and live-model acceptance remain pending.


✅ Send Action-only audit (2026-10-10): remove automatic Agent.send native Tool declarations and the per-role exposesNativeCommunicationTools switch. Every role keeps authorized send Action declarations, target/kind/parameter documentation and receipt/task ownership contracts. Existing business Tools and historical native call/result evidence remain unchanged. Reject an explicit communication Tool registration instead of silently exposing it. Regression tests check all seven effective model catalogs and task request/progress/input/result flows using Action-call send, including roles with business Tools.
