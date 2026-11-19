# ReACT 工具观察后的回复字幕

## 目标与原因

全双工 Assistant 将 Action 与 native Tool 结果转换为新输入时遗漏 turn，后续 beginReplyTurn 跳过、print 被字幕轮次围栏拒绝。用户要求网页观察等 ReACT 后续回复正常显示。

## 实施范围（已完成）

- `MobileHarness/Agents/Assistant/AssistantChatWorker.swift`：两种结果输入继承来源 input 的 turn 与 taskScope；结果消息 ID、来源、父子关系保持原有独立归属。新模型请求继续生成独立 Decision 身份，并通过现有 beginReplyTurn 替换字幕。
- 不更改 Actions 的会话、取消轮次、来源、Decision、Task 和序号校验；没有呈现轮次的后台输入不凭空创建轮次。队列、取消与生命周期仍由 Assistant 拥有。
- `Tests/Agents/Core/GenerationRoundTests.swift`：使用替身模型和真实字幕接纳策略覆盖 Action/native Tool 结果后的正文显示、旧 Decision 拒绝及取消轮次拒绝。
- 实施后同步 Assistant README 和测试 README；跨模块接口不变。

## 验证

两条字幕回归通过，五个 iOS 模拟器目标构建通过；完整检查存在其他用例失败与人工终止的卡住目标，不能标为通过。原始失败、复查结果及限制见[验证记录](../validation/ReACT-Reply-Captions.md)。真机网页、真实模型与原生字幕渲染为独立验收，不以替身结果代替。
