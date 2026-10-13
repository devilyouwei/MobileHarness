# Photographer

## 职责与边界

✅ 摄影确定性执行、相机事实和机械追踪，不负责对话或调用摄影模型。 Agents 管业务策略和上下文，Gateway 管权限/传输，Actions 管函数实现；原生设备与 UI 端口由 App 注入。没有跨 Agent 共享可写聊天历史。

## 文件分工

PhotographerAgent.swift 管生命周期、接纳、持久化与输出；PhotographerCameraWorkflow.swift 管固定摄影步骤；PhotographerTrackingPolicy.swift 管追踪；PhotographerProcessing.swift 管结构化状态和预处理。

## 输入、输出与流程

UI 的可信摄影事务直接进入该 Agent；Vision publish 提供最新姿态；camera.state 更新被动状态。固定调用的结果回原执行者。Assistant 摄影 Skill 直接发 Camera Action，不通过该 Agent 转发用户聊天。

## Context 与 Builder

摄影事务、相机状态、追踪目标、调用关联、任务状态。 状态通过独立 Repository 原子提交；Builder 选择确定版本，不修改已发出的请求。写入失败不产生依赖未提交状态的新调用。

## 生命周期、容量与失败

✅ 已实现（2026-10-13）：PhotographerAgent.prepareSignal 明确保留最近 4096 条 Signal 证据及消费批次，最旧证据淘汰计数持久化；已满的有效 context 首次新输入即可收敛。相机当前状态、调用关联和任务独立保存，证据淘汰不丢弃待执行动作；真实写入失败继续传播。

相机命令与追踪独立；追踪仅在权限/连接/前台条件成立时运行。旧版自然语言 task.request 拒绝，不创建 Chat worker。 事务/输出消费由 App 根生命周期持有，独立于页面。输出最多 256，状态提交等待最多 32；通信消费者最多 16 待处理、4 并发。超限明确失败。取消加入已接纳工作清理；重启标记未完成任务中断，不重放设备动作。共享 Chat 的输入、调用和执行预算见 [Chat](../Support/Chat/README.md)。

## 函数权限与注册

[Agent.json](../../Resources/Agents/Photographer/Agent.json) 声明固定函数；业务模型目录由加载 Skill 决定。实际实现/参数契约以 [owning @Action declarations](../../Actions/README.md) 为准。Internal 固定函数不会自动向模型开放。

本角色没有对话 worker。以下为本角色固定函数声明；实际固定调用由该角色 workflow 注册，不能把固定函数表误认为普通对话目录。

| 类型 / Channel | 别名 | 函数 | 参数 | 说明 |
| --- | --- | --- | --- | --- |
| action / Camera | `flipCamera` | `Camera.Capture.flip` | facing 必填 | Select the requested lens on an enabled camera. Already-selected lens is unchanged; disabled/busy/unavailable fails. Returns lens state. |
| action / Camera | `closeCamera` | `Camera.Capture.close` | — | Disable camera preview/vision and join cleanup. Returns the resulting camera state. |
| action / Camera | `openCamera` | `Camera.Capture.open` | — | Enable camera preview/vision; permission is required. Returns capture readiness, not pose-model readiness. |
| action / Camera | `takePhoto` | `Camera.Capture.takePhoto` | — | Capture once with the ready foreground camera, show preview and return photoID/image evidence. Does not save to Photos. |
| action / Camera | `savePhoto` | `Camera.Capture.savePhoto` | photoID 必填 | Save the displayed captured photo to Photos; permission denial fails. Returns the save receipt. Repeated saves do not duplicate it. |
| action / Camera | `ignorePhoto` | `Camera.Capture.ignorePhoto` | photoID 必填 | Discard the displayed preview without exporting or deleting an album photo. Returns the discard receipt; camera remains open. |
| action / Camera | `retryCamera` | `Camera.Capture.retry` | — | Retry a failed foreground camera operation on explicit user request. |

## 固定内部权限

| Protocol | Canonical function | Channel | Parameters | Registration source |
| --- | --- | --- | --- | --- |
| InternalTool | `NexArm.Tracking.aim` | — | `base`, `pitch` | [PhotographerAgent.swift](PhotographerAgent.swift) |
| InternalTool | `Camera.Capture.open` | — | — | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |
| InternalTool | `Camera.Capture.close` | — | — | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |
| InternalTool | `Camera.Capture.flip` | — | `facing` | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |
| InternalTool | `Camera.Capture.retry` | — | — | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |
| InternalTool | `Camera.Capture.savePhoto` | — | `photoID?` | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |
| InternalTool | `Camera.Capture.ignorePhoto` | — | `photoID?` | [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) |

### Declared input schemas

| Contract | Version | Kind |
| --- | --- | --- |
| `camera.state` | 1 | `observation` |
| `vision.pose` | 1 | `observation` |
| `photography.camera` | 1 | `observation` |
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

✅ 收紧资源中的输入与通信：移除普通用户文本、模型轮次反馈和合成/回复占用权限；仅保留当前确定性流程实际消费的协议。最大函数可复用权限保持独立。

## 输入与通信授权

| 输入契约 | 类型 |
| --- | --- |
| `camera.state` | observation |
| `vision.pose` | observation |
| `photography.camera` | observation |
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
| subscribe | `camera.state` | `phone.camera` |
| subscribe | `vision.pose` | `visionPerception` |
| subscribe | `photography.camera` | `runtime` |
| subscribe | `photography.camera` | `user` |


## 固定函数与 Skill

✅ 资源不再包含 Permissions.json，Agent.json 的 baseSkills 引用 Skill，Skill.json 声明函数。业务模型函数由已加载 Skill 提供；固定调用与模型轮次分别验证，详见 [资源规范](../../Resources/Agents/README.md)。

## Agent → Skill → Function registration

✅ Implemented: Agent.json references baseSkills; Skill.json alone registers model Actions/Tools. BasicSkill owns task orchestration and environment reading; ExpressionInteraction owns expression Actions. Role instructions retain identity/responsibility/style. Business roles reuse existing Skills; internal trusted bindings remain separate. Fixed transaction/task snapshots remain authoritative.

角色基础函数目录由资源中的 baseSkills（photography）组合；上表供函数 review 使用，不是 Agent.json 中的另一份注册。函数说明属于实现，流程教学属于 Skill。

✅ 本次提示词精简同步注册函数说明，保持职责、类型和参数不变；公共执行语义见Actions owning README。

## 历史记录收敛（2026-10-13）

✅ 已实现：历史记录页面仅保留 Assistant 聊天记录与任务记录。Assistant context 是聊天持久化事实源，任务按持久化身份关联；页面板块重新设计另行开展。

❌ 历史记录页面板块重新设计及原生 UI/真机验收。
