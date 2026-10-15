# ApplicationControl

## 职责与边界

✅ 配置、模型资源和设备事务、环境事实；不承担普通对话。 Agents 管业务策略和上下文，Gateway 管权限/传输，Actions 管函数实现；原生设备与 UI 端口由 App 注入。没有跨 Agent 共享可写聊天历史。

## 文件分工

ApplicationControlAgent.swift 管生命周期/事务和环境；ApplicationControlWorkflow.swift 管确定性步骤；ApplicationControlProcessing.swift 管状态与预处理。

## 输入、输出与流程

UI 数据操作直接提交可信事务；导航、展开和筛选留在 UI。Assistant application-control Skill 可以调用同一批 Action 控制 UI 或设备；函数复用不要求委派 Agent。

## Context 与 Builder

待执行调用、环境契约、事务关联。 状态通过独立 Repository 原子提交；Builder 选择确定版本，不修改已发出的请求。写入失败不产生依赖未提交状态的新调用。

## 生命周期、容量与失败

✅ 已实现（2026-10-13 scopeClosed 修复）：ApplicationControlAgent.prepareSignal 明确选择最近 4096 条 Signal 证据及消费批次，超限从最旧记录淘汰并累计淘汰计数。已有 8192 条有效 context 在首次新输入的原子提交中收敛，不清空模型配置或任务状态。pending 调用、任务和环境当前值由独立状态持有，证据不是待执行队列；保留现有写入失败传播和终止语义。容量饱和不应终止服务或关闭根设置通信 scope。

设置页机械臂测试仍保留自身注册。环境 publish 单向、目标拒绝不影响发送者；有确认的 send 仅用于真正独立的后台事务。 事务/输出消费由 App 根生命周期持有，独立于页面。输出最多 256，状态提交等待最多 32；通信消费者最多 16 待处理、4 并发。超限明确失败。取消加入已接纳工作清理；重启标记未完成任务中断，不重放设备动作。共享 Chat 的输入、调用和执行预算见 [Chat](../Support/Chat/README.md)。

## 函数权限与注册

[Agent.json](../../Resources/Agents/ApplicationControl/Agent.json) 声明固定函数；业务模型目录由加载 Skill 决定。实际实现/参数契约以 [owning @Action declarations](../../Actions/README.md) 为准。Internal 固定函数不会自动向模型开放。

本角色没有对话 worker。以下为本角色固定函数声明；实际固定调用由该角色 workflow 注册，不能把固定函数表误认为普通对话目录。

| 类型 / Channel | 别名 | 函数 | 参数 | 说明 |
| --- | --- | --- | --- | --- |
| action / Display | `openPage` | `UI.Navigation.open` | destination 必填 | On a conversational request, open the requested application page through authorized UI presentation. Touch navigation is local and does not call this Agent. |
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
| tool / — | `ModelResources.snapshot` | `System.ModelResources.snapshotResources` | — | Read current shared model resource inventory, installed groups and progress. Does not download, remove or switch a model. |
| tool / — | `Provider.readSettings` | `System.Provider.readSettings` | — | Read confirmed cloud-enabled status and selected cloud model. Contains no URL/key. Does not probe provider availability or change configuration. |
| tool / — | `Bluetooth.readStatus` | `System.Device.readStatus` | — | Read current Bluetooth power/connection and discovered device IDs. Does not scan or move a robot. |
| action / System | `Bluetooth.control` | `System.Device.control` | operation 必填, id | Submit an explicit Bluetooth connection/discovery command. Accepted is not connected or physically completed. Read status to confirm actual state. |
| tool / — | `App.readEnvironment` | `System.Device.readEnvironment` | — | Read the latest admitted scene, navigation and device capability facts only when needed and absent from context. These are observations, not proof of physical completion. Wait for the result before deciding dependent actions. |
| action / System | `ModelResources.download` | `System.ModelResources.download` | id 必填, endpoint 必填, allowsCellular 必填 | Admit a model download using an explicit source. Admission does not mean installed; read the shared inventory for progress. |
| action / System | `ModelResources.cancel` | `System.ModelResources.cancel` | id 必填 | Cancel and join an admitted model transfer. Failure is returned without replay. |

## 固定内部权限

| Protocol | Canonical function | Channel | Parameters | Registration source |
| --- | --- | --- | --- | --- |
| InternalTool | `System.Device.control` | — | `operation`, `id?`, `value?`, `action?`, `fence?` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.Navigation.open` | — | `destination` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.download` | — | `id`, `endpoint`, `allowsCellular` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.cancel` | — | `id` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.remove` | — | `id` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.Provider.restoreSettings` | — | `requestID` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.Provider.saveSettings` | — | `requestID` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.ResourcePresentation.showProviderResult` | — | `requestID`, `failureCode?` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.Provider.discoverModels` | — | `requestID` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.snapshotResources` | — | — | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.ResourcePresentation.showResources` | — | `generation` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.ResourcePresentation.showResourceFailure` | — | `generation`, `message` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.ResourcePresentation.showResourceOperationFailure` | — | `message` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `UI.ResourcePresentation.showResourcePreferenceFailure` | — | `reason`, `message` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.restoreSource` | — | — | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.saveSource` | — | `endpoint`, `allowsCellular`, `recognition`, `synthesis` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |
| InternalTool | `System.ModelResources.configureSpeech` | — | `recognition`, `synthesis` | [ApplicationControlProcessing.swift](ApplicationControlProcessing.swift) |

### Declared input schemas

| Contract | Version | Kind |
| --- | --- | --- |
| `action.result` | 1 | `actionResult` |
| `app.environment` | 1 | `observation` |
| `app.interaction` | 1 | `observation` |
| `provider.settings` | 1 | `observation` |
| `provider.discovery` | 1 | `observation` |
| `model.resource.hostFailure` | 1 | `observation` |
| `model.resource.state` | 1 | `observation` |
| `model.resource.intent` | 1 | `observation` |
| `tool.result` | 1 | `toolResult` |
| `task.request` | 1 | `observation` |
| `task.input` | 1 | `observation` |
| `task.progress` | 1 | `observation` |
| `task.result` | 1 | `observation` |
| `task.cancel` | 1 | `observation` |
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
| `app.environment` | observation |
| `app.interaction` | observation |
| `provider.settings` | observation |
| `provider.discovery` | observation |
| `model.resource.hostFailure` | observation |
| `model.resource.state` | observation |
| `model.resource.intent` | observation |
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
| subscribe | `model.resource.intent` | `runtime` |
| subscribe | `model.resource.state` | `model.resources` |
| subscribe | `model.resource.hostFailure` | `app.resources` |
| subscribe | `app.environment` | `app.environment` |
| subscribe | `app.interaction` | `user` |
| subscribe | `model.resource.intent` | `user` |
| subscribe | `provider.settings` | `user` |
| subscribe | `provider.discovery` | `user` |


## 固定函数与 Skill

✅ 资源不再包含 Permissions.json，Agent.json 的 baseSkills 引用 Skill，Skill.json 声明函数。业务模型函数由已加载 Skill 提供；固定调用与模型轮次分别验证，详见 [资源规范](../../Resources/Agents/README.md)。

## Agent → Skill → Function registration

✅ Implemented: Agent.json references baseSkills; Skill.json alone registers model Actions/Tools. BasicSkill owns task orchestration and environment reading; ExpressionInteraction owns expression Actions. Role instructions retain identity/responsibility/style. Business roles reuse existing Skills; internal trusted bindings remain separate. Fixed transaction/task snapshots remain authoritative.

角色基础函数目录由资源中的 baseSkills（application-control）组合；上表供函数 review 使用，不是 Agent.json 中的另一份注册。函数说明属于实现，流程教学属于 Skill。

✅ 本次提示词精简同步注册函数说明，保持职责、类型和参数不变；公共执行语义见Actions owning README。

✅ ApplicationControl注册调整：Bluetooth.control、ModelResources.download/cancel改为System Channel的Action Call；snapshot/readSettings/readStatus保持原生Tool，11个NexArm对话动作仅由RobotInteraction注册，ApplicationControl Skill不再重复注册。别名、参数、函数实现与内部固定调用不变；模型加载后的XML教学、revision和组合/解析回归同步更新。


✅ Skill scope review: application-control exposes seven navigation/status/System entries only. Removing robot model bindings does not remove trusted device-operation or settings Action implementations.


✅ scopeClosed 修复验证：真实手机的原 8192 条 context 在修复版启动后自动收敛为 4096 条，restoreSource 与后续 Tool 结果成功；满额持久化回归和完整串行测试通过。❌ 模型推理/原生页面显示及声学效果仍是独立验收。详见 [验证记录](../../../docs/validation/Validation-History.md#2026-10-13--saturated-applicationcontrol-context-and-scopeclosed-recovery)。
