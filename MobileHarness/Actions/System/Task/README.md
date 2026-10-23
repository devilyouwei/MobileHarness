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
