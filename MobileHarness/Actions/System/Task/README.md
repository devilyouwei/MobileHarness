# System/Task — 业务能力与执行

## 职责与关系

公开地址为 Agent.Task，源码归 System 的任务控制业务。端点只验证调用准入并转发完整上下文；Agent 拥有 Skill、Task、取消和完成屏障。无 handler 明确失败，注册不授予权限。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [TaskActions.swift](TaskActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [TaskControlEndpoint.swift](TaskControlEndpoint.swift) | Task 请求身份准入，上游拥有实际任务状态 |
| [TaskControlModule.swift](TaskControlModule.swift) | Task 函数的中立端口绑定 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)

## Execution ownership and lifecycle

TaskControlEndpoint validates the bound root/session and invokes TaskControlBinding, a neutral injected host capability. It does not authorize an assistant role or retain AgentContainer/AgentManager. Agents owns Task/Skill policy and binds the actual Task controller through App.

startTask(goal,execution?,executor?,skills?,taskID?,replaceCurrent?,title?,entry?,businessContract?,payload?) 是统一的调度 XML 入口。execution 默认 foreground，仅接受 goal/skills/execution；当前 Agent 管理前台 Task 与 Skills。background 必须指定 executor，创建独立后台执行，不切换前台 Task 或 Skill 目录。当前公开创作执行者为 writer，不能直接与用户对话；后台 Agent 或未来进程适配端点均沿既有认证 TaskSignal，不在 Actions 内启动模型或进程。

BasicSkill 集中注册 start/finish/cancelTask、sendMessage 及 load/release Skills，全部是 Control Channel 的 XML Action，不注册原生工具。后台 startTask 只等接纳，不占 Channel 等待创作；finishTask 只能结束当前前台 Task，后台完成/失败由执行者决定。

Writer 后台启动由运行时选择 writer.author 契约并附原始用户输入，goal 为不含源码的单行目标，支持 taskID 续作、replaceCurrent 授权替代及 title/entry；拒绝模型指定 workspaceID、skills、businessContract/payload。其他后台 executor 继续验证既有注册 businessContract/payload。startTask 的30秒接纳期限覆盖替代时最多25秒清理确认，不限制 Writer 任务耗时。cancelTask(reason) 只取消当前前台任务；cancelTask(executor,taskID,reason) 按可信后台任务身份发送取消，接纳仅表示取消已递送，必须等待后续终态才能确认清理。sendMessage(executor,taskID,text) 当前仅补充 Writer 输入；运行时解析并核对本次输入捕获的待答身份，不接收模型提供的 interactionID、type 或 cancel。

startTask foreground creates Assistant work; background sends an Assistant-generated UUID delegation. Writer allocates or resumes task_N after acceptance. sendMessage(executor,taskID,text) and cancelTask(executor,taskID,reason) resolve the current delegation internally. Internal delegate/interaction UUIDs are not model parameters. Completion terminates a delegation, not the lifetime of its workspace task.

跨模块认证、接纳与完成时序见[总体委托流程](../../../README.md#assistant-agent-delegation)，调用方政策见 [Assistant](../../../Agents/Assistant/README.md#对其他-agent-的委托)，创作、通知和长期作品任务见 [Writer](../../../Agents/Writer/README.md)。
