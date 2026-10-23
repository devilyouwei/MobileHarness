# System/Device — 业务能力与执行

## 职责与关系

函数解析并限定操作专用参数，端口负责真实准入与结果。控制返回 accepted 不代表蓝牙已连通或电机到位；机械臂具体适配属于 NexArm/Connection。缺少环境能力明确返回 unavailable。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [DeviceActions.swift](DeviceActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [DeviceCapabilities.swift](DeviceCapabilities.swift) | 设备请求值、控制端口和明确失败 |
| [DeviceModule.swift](DeviceModule.swift) | 设备状态／环境／操作绑定 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)
