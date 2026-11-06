# Speech/Detection — 业务能力与执行

## 职责与关系

检测只消费角色已计算的观测值；原始 PCM 订阅属于角色。每个检测有一个原生作用域和一个呈现任务，准备／就绪以容量一的信号关联；新请求不能借用旧就绪。采集和清理错误一起保留，停止必须取消并加入实际工作。

原生启动失败、运行失败和 NSError 原样传播；仅已定义的权限、格式、容量、占用和中断错误映射为检测错误，不将设备运行故障归为 PCM 格式错误。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [AudioDetectionCapabilities.swift](AudioDetectionCapabilities.swift) | 检测执行端口 |
| [AudioDetectionPresentation.swift](AudioDetectionPresentation.swift) | 检测就绪信号、UI 代际与操作完成 |
| [AudioDetectionExecution.swift](AudioDetectionExecution.swift) | 原生检测准备、采集事实和清理 |
| [AudioDetectionTypes.swift](AudioDetectionTypes.swift) | 角色产生的检测测量值 |
| [DetectionActions.swift](DetectionActions.swift) | 业务函数的参数校验、能力调用与完成值 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)

## Execution ownership and lifecycle

AudioDetectionSession is Actions-owned native orchestration. DetectionConnections carries generic observation/input ports; Agents supplies cognitive callbacks through App binding. AudioDetectionReadiness and AudioDetectionError are neutral contracts. SpeechPerception retains model/consent/observation policy, without owning native session execution. ActionsContainer retains diagnostic/native stop cleanup.
