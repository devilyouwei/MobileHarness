# NexArm/Support — 跨能力共享机制

## 职责与关系

跨有限动作、手动与跟踪共用的业务请求、错误、逐电机结果与经验参数。连接／控制工作流、有限动作计划和跟踪算法归各业务目录。

本目录由所属域及其业务能力消费，不持有异步任务、原生设备或应用装配。

## 文件与接口

| 文件 | 当前职责 |
| --- | --- |
| [NexArmMotorExecution.swift](NexArmMotorExecution.swift) | 动作电机结果、SDK反馈配置兼容别名与执行失败 |
| [NexArmMotorProfiles.swift](NexArmMotorProfiles.swift) | 动作Step中的原生参数解析（容差/预算由SDK拥有） |
| [NexArmTypes.swift](NexArmTypes.swift) | 跨动作的请求、参数错误与报告代码 |

[所属域设计](../README.md) · [公共契约](../../Support/Contracts/README.md)

`NexArmMotorCompletion` 仅是SDK `NexArmFeedbackConfiguration` 的兼容别名，非法配置返回SDK invalidMotion。

原生运动参数默认值和合法范围引用 PlatformKit `NexArmDeviceLimits`；本层只传递参数及解释业务结果，不另定义设备限制。

`GestureRequest` carries optional `target` (absolute counts) or `deltaDegrees` (relative degrees) for a motor move; the Action validates their exclusive choice before dispatch. Neither field is used to guess a reset home.
