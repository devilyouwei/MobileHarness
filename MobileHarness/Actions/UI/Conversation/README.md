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
| [VoicePresentationHandling.swift](../../Support/Contracts/VoicePresentationHandling.swift) | 仅含 UI 呈现的会话端口 |
| [VoiceStateActions.swift](VoiceStateActions.swift) | 业务函数的参数校验、能力调用与完成值 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)

## Execution ownership and lifecycle

ConversationPresentation uses neutral ConversationTurn and FunctionInput correlation/session fields. Role authorization is performed by Agents before Gateway admission. Business ordering, transcript/reply sequence and session/generation fences remain authoritative here.

## 字幕所有者与输入边界

SpeechPerception 用 UI.Caption.setTranscript/finishTranscript 更新并封口转写槽。回复由 UI.Caption.beginReplyTurn 开启并替换上一条回复字幕，转写槽保留。调用边界校验会话、UI token 和来源。Agent 调用经过 Gateway，Actions 内部呈现组合通过窄端口直达执行服务。

ConversationPresentation 分别追踪识别轮次和回复身份。识别按轮次及更新序号接纳，封口后拒绝同轮片段。回复按来源序号及当前轮次、来源、Decision 和 Task 身份接纳。来源账本最多 32 项。排队回复可以在较晚的识别轮次中用新的回复身份建立字幕。beginRecognitionScope 重置识别围栏，根或会话关闭时清理呈现状态。
