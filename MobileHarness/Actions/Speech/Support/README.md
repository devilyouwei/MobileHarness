# Speech/Support — 跨能力共享机制

## 职责与关系

播放、聆听、检测共用的能力协议、错误与反馈配置。原生会话、播放和检测执行分别归对应业务目录。

本目录由所属域及其业务能力消费，不持有异步任务、原生设备或应用装配。

## 文件与接口

| 文件 | 当前职责 |
| --- | --- |
| [SpeechCapabilities.swift](SpeechCapabilities.swift) | 跨语音能力使用的播放／聆听契约 |
| [SpeechTypes.swift](../../Support/Contracts/SpeechTypes.swift) | 共享语音错误与反馈配置 |

[所属域设计](../README.md) · [公共契约](../../Support/Contracts/README.md)

SpeechListeningCapability 同时提供内部策略应用 updateListening 和公开意图执行 setListening；后者不接收 revision/paused，默认实现明确抛出 listeningUnavailable，保证缺失控制能力不会伪造成功。SpeechModule 的显式聆听依赖绑定这两个入口。
