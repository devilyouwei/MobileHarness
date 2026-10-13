# Assistant

## 职责与边界

✅ 唯一用户对话入口，负责动态 Skill、一个前台目标任务、模型决策和 ReACT。 Agents 管业务策略和上下文，Gateway 管权限/传输，Actions 管函数实现；原生设备与 UI 端口由 App 注入。没有跨 Agent 共享可写聊天历史。

## 文件分工

AssistantAgent.swift 是共享 worker 的业务类型别名；AssistantProcessing.swift 定义预处理、结构化状态、请求策略与照片所有权。

## 输入、输出与流程

用户文本与最终 ASR FIFO；起音绑定当时任务，迟到识别不能改投新任务。camera.state 更新被动事实。每轮选择不可变 Context、Skill 和有效函数目录，输出经 Gateway 执行，结果只回 Assistant。

## Context 与 Builder

history、skillState（任务/加载事件/输入关联）、cameraState 和后台任务报告；普通对话与任务选择各自历史，任务结束只向默认请求提供简短结果摘要。 状态通过独立 Repository 原子提交；Builder 选择确定版本，不修改已发出的请求。写入失败不产生依赖未提交状态的新调用。

## 生命周期、容量与失败

基础 Skill 来自 Agent 配置（basic-skill、expression-interaction、robot-interaction）；任意任务目标按需组合 Skill，默认交互链临时加载的能力在链结束释放。startTask 后下一轮才开放新函数；waitingUser 不关闭任务。finish/cancel 在本轮反馈和回复屏障完成后恢复默认。 事务/输出消费由 App 根生命周期持有，独立于页面。输出最多 256，状态提交等待最多 32；通信消费者最多 16 待处理、4 并发。超限明确失败。取消加入已接纳工作清理；重启标记未完成任务中断，不重放设备动作。共享 Chat 的输入、调用和执行预算见 [Chat](../Support/Chat/README.md)。

## 函数权限与注册

[Agent.json](../../Resources/Agents/Assistant/Agent.json) 声明固定函数；业务模型目录由加载 Skill 决定。实际实现/参数契约以 [owning @Action declarations](../../Actions/README.md) 为准。Internal 固定函数不会自动向模型开放。

下表为可通过 Skill 使用的业务函数及固定控制总览，不代表全部同时开放。Assistant 的当前模型目录由默认能力、已加载 Skill 与控制 Actions 组成；send 由授权通信契约派生且只使用 Action Call。

| 类型 / Channel | 别名 | 函数 | 参数 | 说明 |
| --- | --- | --- | --- | --- |
| action / Display | `express` | `UI.Expression.express` | emotion 必填 | Perform one eye expression, awaiting its transition and return to the current base expression. Each call is a fresh performance. Does not change captions or speech. |
| action / Display | `setExpression` | `UI.Expression.setExpression` | emotion 必填 | Set the persistent base eye expression until replaced, cleared or reset on new user speech. Completes on state acceptance, not animation completion. Repeating the same emotion is idempotent. |
| action / System | `readEnvironment` | `System.Device.readEnvironment` | — | Read the latest admitted scene, navigation and device capability facts only when needed and absent from context. These are observations, not proof of physical completion. Wait for the result before deciding dependent actions. |
| action / Robot | `shakeBase` | `NexArm.Motion.shakeBase` | cycles 必填, speed, acceleration | Perform the configured base-shaking gesture and return home. |
| action / Robot | `waveWrist` | `NexArm.Gesture.waveWrist` | count 必填, speed, acceleration | Wave the wrist with the configured arm gesture, then return home. |
| action / Robot | `tiltWrist` | `NexArm.Gesture.tiltWrist` | direction 必填, speed, acceleration | Tilt the wrist in the requested direction and return home. |
| action / Robot | `lookAround` | `NexArm.Gesture.lookAround` | cycles 必填, speed, acceleration | Perform the configured arm look-around gesture and return home. |
| action / Robot | `celebrate` | `NexArm.Gesture.celebrate` | cycles 必填, speed, acceleration | Perform the configured celebration gesture and return home. |
| action / Robot | `dance` | `NexArm.Gesture.dance` | cycles 必填, speed, acceleration | Perform the configured arm dance and return home. |
| action / Robot | `nodHead` | `NexArm.Gesture.nodHead` | cycles 必填, speed, acceleration | Nod using motor4, returning home; leave other motors untouched. |
| action / Robot | `shakeHead` | `NexArm.Gesture.shakeHead` | cycles 必填, speed, acceleration | Shake the head using motor5, returning home; leave other motors untouched. |
| action / Robot | `resetArm` | `NexArm.Motion.reset` | speed, acceleration | Reset configured homes for motors1–5; never move the gripper. |
| action / Robot | `moveMotor` | `NexArm.Motion.moveMotor` | motor 必填, target 必填, speed, acceleration | Move only the selected motor to its native encoder target. |
| action / Robot | `resetMotor` | `NexArm.Motion.resetMotor` | motor 必填, speed, acceleration | Reset only the selected motor to its configured home; motor6 needs an explicitly configured home. |
| action / Camera | `flipCamera` | `Camera.Capture.flip` | facing 必填 | Select the requested lens on an enabled camera. Already-selected lens is unchanged; disabled/busy/unavailable fails. Returns lens state. |
| action / Camera | `closeCamera` | `Camera.Capture.close` | — | Disable camera preview/vision and join cleanup. Returns the resulting camera state. |
| action / Camera | `openCamera` | `Camera.Capture.open` | — | Enable camera preview/vision; permission is required. Returns capture readiness, not pose-model readiness. |
| action / Camera | `takePhoto` | `Camera.Capture.takePhoto` | — | Capture once with the ready foreground camera, show preview and return photoID/image evidence. Does not save to Photos. |
| action / Camera | `savePhoto` | `Camera.Capture.savePhoto` | photoID 必填 | Save the displayed captured photo to Photos; permission denial fails. Returns the save receipt. Repeated saves do not duplicate it. |
| action / Camera | `ignorePhoto` | `Camera.Capture.ignorePhoto` | photoID 必填 | Discard the displayed preview without exporting or deleting an album photo. Returns the discard receipt; camera remains open. |
| action / Camera | `retryCamera` | `Camera.Capture.retry` | — | Retry a failed foreground camera operation on explicit user request. |
| tool / — | `History.list` | `History.Conversation.list` | offset 必填, limit 必填 | List current and archived conversations, current first then newest archives. Returns paged JSON metadata with IDs and explicitly truncated title/input previews. Start at offset 0; use nextOffset for more. |
| tool / — | `History.read` | `History.Conversation.read` | id 必填, offset 必填, limit 必填 | Read a conversation by an ID returned by History.list. Turns are oldest first. Returns paged JSON with bounded user/response previews and truncation flags, not complete text; never replays behavior. Start at offset 0. |
| action / Display | `openPage` | `UI.Navigation.open` | destination 必填 | On a conversational request, open the requested application page through authorized UI presentation. Touch navigation is local and does not call this Agent. |
| tool / — | `ModelResources.snapshot` | `System.ModelResources.snapshotResources` | — | Read current shared model resource inventory, installed groups and progress. Does not download, remove or switch a model. |
| tool / — | `Provider.readSettings` | `System.Provider.readSettings` | — | Read confirmed cloud-enabled status and selected cloud model. Contains no URL/key. Does not probe provider availability or change configuration. |
| tool / — | `Bluetooth.readStatus` | `System.Device.readStatus` | — | Read current Bluetooth power/connection and discovered device IDs. Does not scan or move a robot. |
| action / System | `Bluetooth.control` | `System.Device.control` | operation 必填, id | Submit an explicit Bluetooth connection/discovery command. Accepted is not connected or physically completed. Read status to confirm actual state. |
| action / System | `ModelResources.download` | `System.ModelResources.download` | id 必填, endpoint 必填, allowsCellular 必填 | Admit a model download using an explicit source. Admission does not mean installed; read the shared inventory for progress. |
| action / System | `ModelResources.cancel` | `System.ModelResources.cancel` | id 必填 | Cancel and join an admitted model transfer. Failure is returned without replay. |
| action · Control | `loadSkills` | `Agent.Task.loadSkills` | skills 必填 | Atomically load Skills; returns committed state for the following request. |
| action · Control | `releaseSkills` | `Agent.Task.releaseSkills` | skills 必填 | Atomically release non-base Skills; returns committed state for the following request. |
| action · Control | `startTask` | `Agent.Task.startTask` | goal 必填, skills 可选, execution 可选, target 可选, businessContract 可选, payload 可选 | Start a goal and load its Skills; returns committed task state. Foreground omits all background-only fields. |
| action · Control | `finishTask` | `Agent.Task.finishTask` | summary 必填, continueDecision | Close the current Task. Ends this decision by default; continueDecision is only for an explicit remaining new goal. Summary describes the actual outcome. |
| action · Control | `cancelTask` | `Agent.Task.cancelTask` | reason 必填 | Cancel the active Task after cleanup joins; returns committed state. Completed effects are not undone. |

## 固定内部权限

### Internal fixed functions

| Protocol | Canonical function | Channel | Parameters | Registration source |
| --- | --- | --- | --- | --- |
| InternalAction | `UI.Caption.beginReplyTurn` | Display | — | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalAction | `Speech.Playback.speak` | Speech | `audioID` | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |
| InternalAction | `UI.Caption.print` | Display | `text` | [AgentChatWorker.swift](../Support/Chat/AgentChatWorker.swift) |

### Declared input schemas

| Contract | Version | Kind |
| --- | --- | --- |
| `user.text` | 1 | `text` |
| `assistant.control` | 1 | `observation` |
| `tool.result` | 1 | `toolResult` |
| `speech.final` | 1 | `observation` |
| `speech.phase` | 1 | `observation` |
| `action.result` | 1 | `actionResult` |
| `generation.round.result` | 1 | `roundResult` |
| `communication.receipt` | 1 | `communicationReceipt` |
| `task.request` | 1 | `observation` |
| `task.input` | 1 | `observation` |
| `task.progress` | 1 | `observation` |
| `task.result` | 1 | `observation` |
| `task.cancel` | 1 | `observation` |
| `agent.userInput` | 1 | `observation` |

Directed input schemas and static subscriptions are distinct; admission also validates the runtime sender and scope.

### Input subscriptions and communication grants

Publication is one-way and has no recipient acknowledgment. Directed send returns admission; explicit task results report completion.

| Input contract | Source | Topic |
| --- | --- | --- |
| `speech.final` | `speechPerception` | `speech.final` |
| `user.text` | `user` | `user.text` |
| `speech.phase` | `speechPerception` | `speech.phase` |
| `agent.userInput` | `user` | `agent.userInput` |
| `assistant.control` | `runtime` | `assistant.control` |

| Output | Contract | Destination |
| --- | --- | --- |
| publish | `interaction.replyActivity` | Exact static subscribers |
| send | `speech.synthesize` | `speechSynthesis` |
| send | `speech.cancel` | `speechSynthesis` |
| send | `task.request` | `photographer` |
| send | `task.input` | `photographer` |
| send | `task.cancel` | `photographer` |
| send | `task.request` | `memory` |
| send | `task.input` | `memory` |
| send | `task.cancel` | `memory` |
| send | `task.request` | `applicationControl` |
| send | `task.input` | `applicationControl` |
| send | `task.cancel` | `applicationControl` |

## Related design

[Parent design](../README.md)

## 状态与验收

✅ 动态 Skill/确定性职责拆分已实现。❌ 摄影、保存、尾音、语音竞争及模式切换的真机验收仍需单独进行。

## 泛化 Task 与独立 Skill

✅ 泛化 Task 与独立 Skill 已接入：任意目标、单前台任务，基础/交互链/任务 Skill 作用域；后台复用 send，不抢占前台。详见所属 Agents 与公共机制设计。

✅ Audit correction: shared Chat worker must not cast AssistantContextState or interpret camera business facts. Role hooks select/apply passive context observations; Assistant owns provenance/sequence validation and camera/task data-message construction through its own Context Builder. Existing lifecycle, persistence and request snapshot semantics remain unchanged.


## 固定函数与 Skill

✅ 资源不再包含 Permissions.json，Agent.json 的 baseSkills 引用 Skill，Skill.json 声明函数。业务模型函数由已加载 Skill 提供；固定调用与模型轮次分别验证，详见 [资源规范](../../Resources/Agents/README.md)。

## Action-owned documentation and Skill instruction contract

✅ Assistant 提示词分别组装 Core 协议、身份、Skill 概述、当前任务/Skill 指令及有效函数 doc/parameters。移除 orderingExample/concurrentExample 模板插值；顺序及业务示例由基础交互、机器人和摄影 Skill 教学。

## Task controls through Action Calls

✅ BasicSkill 的五个 Task/Skill 控制函数使用 Control Channel Action Call；App 通过 ChannelScheduler 返回已提交状态。startTask/loadSkills/releaseSkills 返回的已提交业务状态在结果屏障后重建目录并 ReACT，finishTask/cancelTask 加入回复及清理屏障后恢复默认。新目录仅影响后续请求，不允许加载轮提前调用新函数。可信固定调用复用同一实现。

## Agent → Skill → Function registration

✅ Implemented: Agent.json references baseSkills; Skill.json alone registers model Actions/Tools. BasicSkill owns task orchestration and environment reading; ExpressionInteraction owns expression Actions. Role instructions retain identity/responsibility/style. Business roles reuse existing Skills; internal trusted bindings remain separate. Historical snapshots are preserved.

角色基础函数目录由资源中的 baseSkills（basic-skill、expression-interaction、robot-interaction）组合；上表供函数 review 使用，不是 Agent.json 中的另一份注册。函数说明属于实现，流程教学属于 Skill。


## Lifecycle-owned conversation and audio (2026-10-12)

✅ 已移除对话生成、ReACT、收件箱排队、结果屏障、ASR 收尾、TTS 合成及回复占用租约的计时终止。Signal 默认无过期时间，框架不再按通信契约附加 TTL。保留显式实时感知数据的新鲜度和网络传输自身超时；它们不作为对话/语音缓存生命周期。Action 自身超时通过原始执行者的 ActionResult 返回。请求/调用数及队列/PCM 容量仍有界，不以计时自动删除已接纳输入。语音句柄无读等待或错误记录 TTL，按播放完成、输入/会话正常结束、异常或显式取消清理；取消加入生成和播放工作。


## Result-driven ReACT (ADR0214)

✅ ADR0214：删除 AssistantContextState.actionFeedback，具体模块/路径不决定继续策略；由实际输出和错误进入 ReACT。照片 enrichment 与 Task 目标/收尾继续由本角色拥有。


✅ 本次提示词核对：保留协议、角色、Skill概述、独立Agent职责、已加载Skill、有效目录顺序；为各段增加明确标题，运行状态以 user 数据说明当前没有任务/已加载Skill。


✅ 提示词精简已实现：合并角色/风格，删除重复system模板；维持协议→角色→Skill概述→独立Agent→已加载Skill→目录→短检查。Task事实投影只含必要状态，不发送完整TaskRecord；RobotInteraction常驻且11项函数不变。

✅ ApplicationControl注册调整：Bluetooth.control、ModelResources.download/cancel改为System Channel的Action Call；snapshot/readSettings/readStatus保持原生Tool，11个NexArm只由常驻RobotInteraction注册，ApplicationControl不再重复注册。别名、参数、函数实现与内部固定调用不变；模型加载后的XML教学、revision和组合/解析回归同步更新。

✅ Task 上下文收缩时机已修正：startTask 成功后保留进入前的普通对话、启动轮输出及完整调用/结果，只刷新当前 Skill/函数目录；后续任务输入继续携带普通对话背景和当前任务过程。仅旧 Task 关闭后收缩其原始过程为有界终态摘要；摘要在新 Task 中仍可作为历史背景，不能变成当前产物。完整持久化历史与不可变 taskID 保持不变；照片操作不再通过 Task 归属额外鉴权；同输入换任务先收缩已结束旧任务，再完整保留新任务入口。10 个历史请求块和64消息/64KiB/4图片容量保护仍独立生效。

✅ 已删除 Assistant 自定义 validateAction、registerPhoto 与 photoOwners；Camera 操作由当前 Skill/函数目录解析执行，无 Task 也能拍摄、接收图片结果、保存或忽略。设备前台/权限/相机就绪由实际函数处理。

照片事实直接来自当前相机快照中的 displayedPhotoID / savedPhotoID；图片证据按拍摄结果实际UUID和产生输入读取，不需要额外 Task 登记。终态摘要从同一持久化Task记录投影，reportedSummary仅为总结说明，实际执行证据仍保留完整历史。新对话不会注入已归档对话的Task摘要。

## 历史记录收敛（2026-10-13）

✅ 已实现：历史记录页面仅保留 Assistant 聊天记录与任务记录。Assistant context 是聊天持久化事实源，任务按持久化身份关联；页面板块重新设计另行开展。

❌ 历史记录页面板块重新设计及原生 UI/真机验收。


✅ Implemented (2026-10-13 Skill scope review): canonical Actions unify trusted business calls and model calls; Skill exposure is optional and must serve an actual procedure. ExpressionInteraction retains two expression functions; Feedback/Notice/Light model exposure is removed while implementations and business bindings remain. ApplicationControl keeps navigation/status/resource/Bluetooth operations, removing duplicate robot functions; RobotInteraction owns them. BasicSkill removes unused send while production background contracts are absent. Affected instructions/revisions and explicit communication-only test catalogs are aligned; all six Skills were audited for prerequisites, result handling and cross-Skill references.


## Task history indexing and in-place compression

✅ Implemented: Assistant validates history schema v2 and projects request-owned task history through conversation compressions. Startup recovery marks unfinished work interrupted and produces terminal history evidence without replay. Camera and media policy remain unchanged.


## 会话存储性能重构 v3

✅ 已实现：当前 history 仅含当前会话，历史归档不进入运行 context。恢复快照保存 Skill、任务及任务视图；恢复不保留运行队列/Signal/相机事实，不重放动作。状态校验不再编码完整历史检查容量。
