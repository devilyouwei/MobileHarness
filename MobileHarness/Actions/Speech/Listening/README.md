# Speech/Listening — 业务能力与执行

## 职责与关系

实际感知注册与模型图属于注入的上游角色；本目录拥有权限、捕获启停、半双工、启动反馈及真实播放屏障。原始 PCM 由感知角色直接订阅。关闭先取消并加入执行和播放，再释放共享音频；页面离开不释放根会话。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [ListeningActions.swift](ListeningActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [ListeningActivationFeedback.swift](ListeningActivationFeedback.swift) | 聆听启动反馈的真实结果组合 |
| [VoiceNativeEffects.swift](VoiceNativeEffects.swift) | 语音会话的提示音、触觉与播放执行 |
| [VoiceOutputHandling.swift](VoiceOutputHandling.swift) | 原生语音端点接口，复用独立 UI 呈现端口 |
| [VoiceSessionConnections.swift](VoiceSessionConnections.swift) | 上游感知生命周期与公开执行依赖 |
| [VoiceSessionCoordinator.swift](VoiceSessionCoordinator.swift) | 权限、采集、半双工播放屏障与根会话清理 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)
