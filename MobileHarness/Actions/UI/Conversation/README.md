# UI/Conversation — 业务能力与执行

## 职责与关系

只接纳匹配会话、轮次、任务与序号的文字及显示状态，转换为基础 UI 自有值。呈现确认与原生播放排空分开，旧 token 不更新替换后的 UI；输出处理不选择 Agent 策略。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [CaptionActions.swift](CaptionActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [ConversationPresentation.swift](ConversationPresentation.swift) | 会话／轮次／任务／序号呈现围栏 |
| [ConversationPresentationController.swift](ConversationPresentationController.swift) | 文字、语音显示与真实呈现确认 |
| [VoicePresentationHandling.swift](VoicePresentationHandling.swift) | 仅含 UI 呈现的会话端口 |
| [VoiceStateActions.swift](VoiceStateActions.swift) | 业务函数的参数校验、能力调用与完成值 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)
