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

UI.Caption.setTranscript/finishTranscript由识别角色提交，只更新转写槽及封口；识别身份变化不再调用resetCaptions。UI.Caption.clearReply由Assistant代码作为内部Display Action发起，参数可携带开口时冻结的replyInputID，不表示开始回复。会话、UI token和来源仍由调用边界校验；执行只清本来源回复，不能清识别字幕。外部调用经过Gateway，Actions内部呈现组合沿已有窄端口直达执行服务，不增加通信。

ConversationPresentation分离识别turn和回复身份。clearReply使用已接纳输入起点、来源序号和当前退休请求围栏；同轮重复／旧起点不再清理，旧请求的后续beginReply及文本不能复活字幕。迟到clear不得抹掉已经开始的另一新请求。来源账本最多32项，沿用生产者准入界限；每来源只保留当前退休请求，正在执行的回复请求由单个Assistant工作流拥有，已经发出的旧调用还受序号和当前身份围栏限制。新的排队回复即使对应较早的输入turn，也可用新请求身份建立字幕。beginRecognitionScope重置识别起点围栏，根／会话关闭保留通用清理。
