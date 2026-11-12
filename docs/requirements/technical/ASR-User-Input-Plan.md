# 语音片段发布与完成文本的 Agent 输入契约

2026-11-12 用户要求先确定信号清单和 Agent.json 的目标结构，并明确 SpeechPerception 继续发布识别片段，Assistant 只订阅完成文本。此文描述拟议方案。

## 主题与契约

语音用户输入共用 `user.input` 主题。契约名按 `user.input.asr.<结果阶段>` 组织，发布端和订阅端使用同一个完整契约名。

| 阶段 | 契约 | 主题 | 接收方 |
| --- | --- | --- | --- |
| 识别片段 | `user.input.asr.partial` | `user.input` | 显式订阅片段的观察方 |
| 最终文本 | `user.input.asr.final` | `user.input` | Assistant 与完整转写观察方 |

Gateway 同时匹配契约、可信来源和主题。共享主题下，只有精确订阅 `user.input.asr.partial` 的接收端才会收到片段。键入文本继续走 UI 直连。

## 目标配置

Assistant 的 `communication`：

```json
{
  "inputs": [
    {"contract": "tool.result", "version": 1, "kind": "toolResult"},
    {"contract": "action.result", "version": 1, "kind": "actionResult"},
    {"contract": "generation.round.result", "version": 1, "kind": "roundResult"},
    {"contract": "communication.receipt", "version": 1, "kind": "communicationReceipt"},
    {"contract": "task.progress", "version": 1, "kind": "observation"},
    {"contract": "task.result", "version": 1, "kind": "observation"},
    {"contract": "writer.completion", "version": 1, "kind": "observation"}
  ],
  "subscriptions": [
    {"contract": "user.input.asr.final", "source": "speechPerception", "topic": "user.input"}
  ],
  "publications": [],
  "sends": [
    {"contract": "task.request", "target": "writer"},
    {"contract": "task.input", "target": "writer"},
    {"contract": "task.cancel", "target": "writer"}
  ]
}
```

SpeechPerception 的 `communication`：

```json
{
  "inputs": [
    {"contract": "action.result", "version": 1, "kind": "actionResult"}
  ],
  "subscriptions": [],
  "publications": ["user.input.asr.partial", "user.input.asr.final", "sound.source"],
  "sends": []
}
```

片段使用 `user.input.asr.partial` 并保留采集会话身份。最终文本使用 `user.input.asr.final`，按交互会话递送。`sound.source` 供声源诊断消费。Assistant 的任务进度和 Writer 完成分别使用 `task.progress` 与 `writer.completion`，运行时终止反馈使用 `task.result`。

## 契约与职责

1. **完整用户输入**。SpeechPerception 在 VAD 切段且 ASR 得到完整非空文本时，对每个有效识别轮次发布一次 `user.input.asr.final`。保留会话、轮次、时间和因果元数据，文本继续执行 4096 UTF-8 字节上限。Assistant 使用和键入相同的用户输入分类和排队入口，依据完成文本接纳时的会话及任务确定归属。识别期间切换任务或出现 Writer 追问时，以接纳时的可用上下文为准，权限和关联身份仍由 cognition 验证。
2. **广播接纳**。当前 `CommunicationPolicy` 要求订阅同时写在 `inputs`，并要求 topic 等于 contract。目标为广播接纳由订阅授权，定向与运行时反馈由 inputs 授权。契约注册表提供载荷类型及唯一主题，版本继续按 v1 校验。OutputGateway 用注册主题构造广播元数据，InputGateway 按投递方式分别校验，匹配契约、主题和可信来源，主题容量按注册主题计算。现有契约缺省使用同名主题，保持其他广播路由兼容。订阅权限不授予定向投递权限。
3. **片段与呈现归感知**。ASR 识别期间发布 `user.input.asr.partial` 并更新本地识别字幕。片段保留采集身份、轮次与原有限额，供观察或未来显式订阅；Assistant 只接收完成文本。发布端与观察端一起迁移原 `speech.partial` 和 `speech.final`，并移除 `speech.phase` 广播。感知内部管理 VAD/ASR 阶段、字幕、灵动岛及空段或失败的收尾。
4. **收音归许可与实际播放**。移除 `interaction.replyActivity` 的发布、订阅、契约及 Gateway 特判。Assistant 的 Decision 和回复占用留在自身。感知在识别收尾完成后独立重置识别器。全双工按采集能力连续识别；受限路由由 VoiceSessionCoordinator 现有实际播放准入与末次播放退出控制暂停及恢复。恢复遵守会话、采集代、用户许可与视频音频占用。ASR 收尾期间保持播放准入屏障，防止重置与播放争用。
5. **代码与文档范围**。同步 Assistant、SpeechPerception 的资源、输入组装与播放/字幕交界，清理旧识别阶段绑定、占用回传和只服务旧契约的测试与文档。共享通信契约、Gateway 的业务适配与总体设计同时更新。

## 消费方核对与迁移

| 现有使用点 | 目标行为 |
| --- | --- |
| Agent.json 中的语音订阅 | 现有生产声明里，Assistant 是唯一订阅 `speech.final`、`speech.phase` 的 Agent；没有 Agent 订阅 `speech.partial`。Assistant 改订阅 `user.input.asr.final`。 |
| AgentRuntime 的 Gateway 观察 | 当前列出 partial、final 和 phase。片段改以 `user.input.asr.partial` 广播，Signal Trace 继续可观察。业务观察器改用 `user.input.asr.final` 记录完整转写。 |
| 空段观察 | 目前 `speech.phase(.empty)` 经过观察器调用 VoiceSessionCoordinator 清理 `handlingTurn`。该清理由本地呈现或采集生命周期接手，并保留会话与播放屏障检查。 |
| 回复占用 | 当前只有 SpeechPerception 订阅 `interaction.replyActivity`。移除发布和订阅前，将受限路由暂停与恢复迁到实际播放生命周期。 |
| 声源与姿态 | AudioDetectionAgentSession 继续观察 `sound.source`，Photographer 继续订阅 VisionPerception 的 `vision.pose`。广播授权调整需要验证这两条已有路线。 |
| 测试观察器 | VoiceTests 用 partial/phase 检查识别过程，CommunicationTests 用 partial/final 检查发布和观察器隔离。片段和最终文本使用新契约验证，阶段改测本地呈现。 |

## 验证

用生产资源验证广播和定向授权隔离，以及错误来源、主题、契约、版本或载荷被拒绝。验证两类语音广播共享主题且各自按契约送达，片段仍可观察，Assistant 只收到完成文本。验证两段连续语音、空段、失败和重复完成，以及最终文本进入 Decision 一次和任务切换按接纳时点处理。覆盖全双工、受限路由的实际播放暂停、取消恢复、用户关闭后不重新开启。运行完整检查与 iOS 构建，独立记录原生收音和真机音频路线验收。

运行结果见 [ASR 用户输入通行验证](../../validation/ASR-User-Input.md)。

## 实施补充

旧回复占用广播是 `runtime.replyFinished` 合成反馈的唯一业务消费者。随广播一并移除该反馈及其诊断过滤。Assistant 继续以本地输入生命周期维护 Decision 占用和回复呈现。旧识别阶段触发的字幕清除退役，识别字幕由感知呈现、回复字幕由实际回复开始时更新。

删除旧空段观察端口后，语音协调器的暂停与恢复由实际播放、视频音频和许可生命周期负责。语音感知在完成文本发送后重置本轮识别；保留采集代及播放准入检查。现有 `speech.partial` 观察测试迁到新片段契约，旧占用回传测试替换为本地播放准入及不依赖 cognition 回执的连续识别验证。

`UI.Caption.clearReply` 只有旧识别开口事件调用。同步删除其 Action 注册、呈现端口、退休请求状态和执行记录过滤项。`UI.Caption.beginReplyTurn` 在实际回复开始时清理回复槽，继续校验会话、来源、序号和回复身份。Actions 的字幕呈现与契约文档、UI 字幕槽文档和相关回归记录按此更新。
