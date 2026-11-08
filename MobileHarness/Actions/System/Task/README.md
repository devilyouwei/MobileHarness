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

BasicSkill 的公开别名为 task.start、task.end、task.delegate、task.cancel、task.send；具体函数地址仍在 Agent.Task，全部通过 Control Channel 调度。loadSkills/releaseSkills 独立管理能力。

| Action | 参数与语义 |
| --- | --- |
| task.start | description、可选 skills JSON 数组；原子启动并加载初始 Skill，下一请求可用，无需重复 loadSkills。平铺前台 scope。有旧任务时先加入其非 Control 效果，保存 superseded，再新建 |
| task.end | summary、可选 continueDecision；只结束前台摘要 scope |
| task.delegate | agent_id、description；向目标发送请求，目标决定 task/workspace |
| task.cancel | reason、可选 agent_id；省略目标取消前台，带目标发送当前通信链的取消 |
| task.send | text、可选 agent_id；省略目标补充前台，带目标发送补充/待答输入 |

不接受公开 taskID、workspaceID、replaceCurrent、业务协议或内部通信 ID。后台委派只等待接纳，目标忙碌明确拒绝，不自动替换。Writer 自行保存本地运行和工作区状态，Assistant 不读取 Writer 私有表。通信送达与业务完成分别处理。前台切换清理失败时保留旧 scope，并拒绝新任务。

跨模块认证、接纳与完成时序见[总体委托流程](../../../README.md#assistant-agent-delegation)，调用方政策见 [Assistant](../../../Agents/Assistant/README.md#对其他-agent-的委托)，创作、通知和长期作品任务见 [Writer](../../../Agents/Writer/README.md)。

start/delegate 的 canonical 教学明确二者为平级入口：调用方自己执行的前台目标用 start，目录内其他所有者的目标直接 delegate。同一目标没有 start 前置条件；独立前台目标仍可与后台工作并存。

## Task 教学的所有权

TaskActions 的 canonical 描述只定义通用前台 start 与 peer delegate 的平级关系、参数及完成语义，不维护接收角色用途。BasicSkill 教如何按公开目录选择所有者；具体角色用途由该角色的 Agent.json.description 维护。目录不是执行授权，实际准入仍由 Agents 适配与 Gateway 完成。
