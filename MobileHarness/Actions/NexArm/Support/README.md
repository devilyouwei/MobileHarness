# NexArm/Support — 跨能力共享机制

## 职责与关系

跨有限动作、手动与跟踪共用的业务请求、错误、逐电机结果与经验参数。连接／控制工作流、有限动作计划和跟踪算法归各业务目录。

本目录由所属域及其业务能力消费，不持有异步任务、原生设备或应用装配。

## 文件与接口

| 文件 | 当前职责 |
| --- | --- |
| [NexArmMotorExecution.swift](NexArmMotorExecution.swift) | 共享电机结果、完成策略与失败类型 |
| [NexArmMotorProfiles.swift](NexArmMotorProfiles.swift) | 共享电机容差及经验预算 |
| [NexArmTypes.swift](NexArmTypes.swift) | 跨动作的请求、参数错误与报告代码 |

[所属域设计](../README.md) · [公共契约](../../Support/Contracts/README.md)
