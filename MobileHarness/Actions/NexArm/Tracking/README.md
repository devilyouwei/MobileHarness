# NexArm/Tracking — 业务能力与执行

## 职责与关系

跟踪只保留最新目标，命令提案与实际接纳分开。每次写入核对输入新鲜度、连接代际与资源许可；退出恢复电机模式并加入原生会话清理。根控制服务拥有跟踪任务，规划状态不创建后台工作。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [NexArmAimCommand.swift](NexArmAimCommand.swift) | 跟踪准备、速度包提案、安静停止与退出恢复 |
| [NexArmTrackingSession.swift](NexArmTrackingSession.swift) | 最新跟踪目标与已接纳命令状态 |
| [TrackingActions.swift](TrackingActions.swift) | 业务函数的参数校验、能力调用与完成值 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)
