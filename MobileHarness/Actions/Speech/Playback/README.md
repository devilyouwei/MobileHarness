# Speech/Playback — 业务能力与执行

## 职责与关系

播放只消费由 Assistant 预留、可继续生产 PCM 的音频句柄，不选择模型或生成语音；借出、真实排空、取消和租约释放均由播放执行拥有。半双工准入由根语音会话管理。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [PlaybackActions.swift](PlaybackActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [SpeechPlayback.swift](SpeechPlayback.swift) | 音频句柄借出、真实播放排空与租约清理 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)
