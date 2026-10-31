# NexArm/Connection — 业务能力与执行

## 职责与关系

连接与控制状态由根控制服务拥有；本目录投影不把连接成功解释为电机到位。恢复预算有界，旧连接代际不能修改新连接；手动停止保留独立入口，停止软件工作不证明物理停机。

本目录由所属域目录绑定，接受标准 FunctionInput；调用授权归 Agents；通用调度与资源仲裁归 Gateway。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [BluetoothInteractionWorkflow.swift](BluetoothInteractionWorkflow.swift) | 有界手动请求与停止入口 |
| [BluetoothPresentation.swift](BluetoothPresentation.swift) | 设备事实的展示名称与状态投影 |
| [BluetoothRecovery.swift](BluetoothRecovery.swift) | 恢复原因/错误展示及存储错误过滤，预算和原生分类来自SDK |
| [BluetoothWorkflow.swift](BluetoothWorkflow.swift) | 业务状态到 UI 的投影及连接／控制端口 |
| [NexArmConnectionState.swift](NexArmConnectionState.swift) | 连接、控制资格、恢复及测量事实 |
| [NexArmDeviceAdapter.swift](NexArmDeviceAdapter.swift) | System.Device 到机械臂能力的类型化适配与延迟失败反馈 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)

## Device read ownership

NexArmDeviceAdapter exposes typed control, specific Bluetooth status and deferred failure delivery. Application/Agent observation and last-result readers are outside this adapter; it has no generic environment callback. Status reads retain Bluetooth ownership and do not scan, connect, move hardware or prove physical completion.

原生运动参数默认值和合法范围引用 PlatformKit `NexArmDeviceLimits`；本层只传递参数及解释业务结果，不另定义设备限制。

原生重连预算、退避、可恢复错误分类及失败类型由 PlatformKit 提供；本层不复制分类。根服务保留记住设备选择、主动断开、前后台/业务资格和恢复任务生命周期。连接/断开/隔离的原生执行及事实一直由SDK拥有；中文提示留在本层。

The workflow forwards relative motor requests without converting units or guessing current position; the connection-owned executor obtains feedback before resolving the target.

## State projection

The business read projection exposes connection/recovery phase independently from native feedback. Native sample age comes from the monotonic receipt instant; disconnected sessions expose no current positions. Internal motion detail is read from the existing controller. State reads create no scan, connection, query or recovery work.
