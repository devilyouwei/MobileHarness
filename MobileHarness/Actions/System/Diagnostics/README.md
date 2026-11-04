# System/Diagnostics — 业务能力与执行

## 职责与关系

显式诊断与授权 Agent Action 执行分开，不从合成检查推导真实业务或设备验收。语音诊断等待真实播放，并在停止时加入合成、卸载和音频会话清理；多项错误保留到根生命周期。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [ChatDiagnosticWorkflow.swift](ChatDiagnosticWorkflow.swift) | 显式合成输入的聊天能力诊断 |
| [SpeechDiagnosticWorkflow.swift](SpeechDiagnosticWorkflow.swift) | 显式语音诊断的加载、合成、播放及清理 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)

聊天诊断请求不指定输出 token 预算，使用已选模型的 Provider 默认值。
