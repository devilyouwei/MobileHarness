# Assistant 拥有聆听判断，感知事实改用 Signal

日期：2026-11-23。

2026-11-26：两个角色当前的接口与事件见 [单向语音通信](One-Way-Speech-Perception.md)。下文记录迁移到 Signal 的前一阶段。

## 问题

1. `quiet` 退出判定（QuietExitJudge、提示词、ListeningCoordinator）位于 SpeechPerception。感知角色不思考、不拥有语言模型，判断 `listening` 状态变化的模型与 pipeline 应属 Assistant。
2. SpeechPerception 通过构造注入的闭包直接调用 Assistant（起声、起声确认、结束、采集代、VAD 窗口），感知角色因此持有 Assistant，`listening` 协调器又反向持有感知角色。Agent 间通信只能经 Gateway 的 publish/subscribe：生产者不知订阅者，Assistant 不引入也不监听其他 Agent，只订阅 Signal。

## 目标契约

| Signal | 发布者 → 订阅者 | 变体 / 载荷 |
| --- | --- | --- |
| `perception.speech.activity.v1`（频道 `perception.speech.activity`） | SpeechPerception → Assistant | `captureStarted`/`captureStopped`（采集代）、`duplexSupport`（当前采集能否全双工）、`onsetStarted`（起声候选开始）、`onsetCleared`（候选在确认前消失）、`onsetConfirmed`（utterance ID）、`utteranceEnded`（utterance ID 已退休：空识别/失败/发布失败）、`utterancesCleared`、`ended`（感知角色停止） |
| `agent.listening.mode.v1`（频道 `agent.listening`） | Assistant → SpeechPerception | 当前 `listening` 值 |

- 载荷只含标识、布尔和模式，不含 PCM 或文本；最终文本仍走 `user.input.speech.v1`。
- 这些 Signal 低频、延迟敏感，按 control 车道准入，不因普通输入满载被拒。仍遵循“发布不重试、迟到订阅不补发”。因此 Assistant 在收到 `captureStarted` 时重新发布当前模式；运行中错过的状态由超时和采集代更替恢复。
- 感知角色不再按 `quiet` 分支：最终文本始终发布。Assistant 在 `quiet` 下不把它交给对话，而是交给判定；`exit` 时先把 `listening` 写回进入前的模式，再按普通语音处理同一输入。

## 变更范围

1. 新增 `Support/Communication/SpeechActivityMessage.swift`（感知事实消息）与 `Assistant/Input/AssistantListeningSignal.swift`（模式消息）；`AgentContracts` 注册契约、事件实现与发布实现；两个角色的 Agent.json 声明发布/订阅；`InputGateway` 的 control 判定改为按契约集合。
2. 将 `QuietExitJudge`、`ListeningCoordinator` 移至 `Assistant/Input/`，提示词移至 `Resources/Agents/Assistant/Input/QuietExit*.json`。协调器不再持有感知角色，通过绑定的发布闭包写模式，由 Assistant 自身记录采集能力并拒绝不可用的 `full`。
3. SpeechPerception 删除 `speechStarted/Ended/CaptureStarted/CaptureStopped/Window` 闭包与 `ListeningRoute`，改为发布活动 Signal，并订阅模式 Signal。
4. Assistant 的打断后起声探测由逐窗计数改为：打断清理后 40 窗口时长（1.28 s）内未出现起声候选且无待定候选，则判定无人说话；候选待定时等待确认或消失。10 s 停滞保护保留。
5. 同步 `Agents/README.md`、`Assistant`、`Assistant/Input`、`SpeechPerception`、`Support/Communication`、`Resources/Agents` README，更新 Tests 与测试 README。不新增目录。

## 验收

自动化：Signal 发布/订阅、模式回灌、quiet 判定与退出、起声探测时序；`./scripts/check.sh` 与可用时的 `./scripts/build-ios.sh`。真机全双工打断与 quiet 流程需独立验收。

## 实施结果

2026-11-23：已实现第 1–5 项。`QuietExitJudge`、`ListeningCoordinator` 与提示词迁入 Assistant 并不再引用感知角色；SpeechPerception 删除五个回调与 `ListeningRoute`，改为发布活动 Signal 并订阅模式 Signal；两角色 Agent.json、契约注册与 control 车道已同步；Assistant 起声探测改为 1.28 s 计时加候选等待。回复活动也已改为 `agent.reply.activity.v1`，感知角色不再有对 Assistant 的注入读取。自动化与真机结果见验证记录。
