# UI/Runtime — 业务能力与执行

## 职责与关系

运行异常分类属于 ApplicationControl，本目录校验已分类值并呈现；蓝牙展示只更新事实，不连接或控制设备。活动观察与频谱状态由根所有者管理，停止取消并加入观察；频谱句柄以根／采集代际隔离。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [ActionActivityPresentation.swift](ActionActivityPresentation.swift) | 执行／任务／信号事实到活动 UI 值的映射 |
| [ActionActivityWorkflow.swift](ActionActivityWorkflow.swift) | 有界活动观察与展示寿命 |
| [BluetoothStatusActions.swift](BluetoothStatusActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [MicrophoneSpectrumPresentation.swift](MicrophoneSpectrumPresentation.swift) | 频谱测量校验、平滑与根／采集代际接纳 |
| [RuntimeDiagnosticsActions.swift](RuntimeDiagnosticsActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [RuntimeIssue.swift](RuntimeIssue.swift) | 已分类运行异常的有界呈现值 |
| [RuntimePresentationCapabilities.swift](RuntimePresentationCapabilities.swift) | 异常、蓝牙状态的呈现契约 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)
