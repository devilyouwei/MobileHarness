# 聆听模式 `listening` 状态变量

## 背景与决定

[状态机泛化](State-Generalization-Task-Removal.md)已把 Agent 自身状态统一为变量表，并预留 Trigger（变量变化 → 预设处理器）。原 `quiet` 是只读 bool，没有 Trigger，只在 `AssistantChatPeerEvents` 处被直接读取，应用中没有任何写入者。

决定：

1. **取消 `quiet` 变量**，以单一类型化枚举变量 `listening` 表示聆听模式，取值 `full`（全双工，默认）、`half`（半双工，回退或用户要求）、`quiet`（仅聆听 / 唤醒模式）。
2. `listening` 绑定 Trigger，由 Trigger 处理器改变聆听与输出行为；其他代码不轮询该变量。
3. `quiet` 模式不是“静音开关”，而是**唤醒模式**：持续聆听、ASR 持续输入，但只由一个独立的轻量判定通道决定何时退出，期间不回复、不主动播报。

## 已实现

已实现部分的当前契约只在代码目录 README 中维护，本文不重复：

| 内容 | 位置 |
| --- | --- |
| Trigger 注册层（处理器、不重入、失败不发布、模型与宿主同一写入入口）、`task` 迁为首个处理器 | [Support/Context](../../../MobileHarness/Agents/Support/Context/README.md#agent-state-variables) |
| `listening` 声明（typed enum、readWrite）与教学说明（Agent.json、Agent.zh-Hans.json） | [Agents/Resources/Agents](../../../MobileHarness/Agents/Resources/Agents/README.md) |
| 三种模式、`full` 的拒绝与回退、`quiet` 路由、退出判定通道、会话结束复位 | [Assistant input](../../../MobileHarness/Agents/Assistant/Input/README.md#listening-and-quiet)（判断归 Assistant，见 [Signal 化](Assistant-Listening-Signals.md)） |
| 感知角色对模式的采纳、灵动岛状态 | [SpeechPerception](../../../MobileHarness/Agents/SpeechPerception/README.md#聆听模式-listening) |
| `quiet` 下同伴报告写入对话但不播报、不作为输入 | [Assistant](../../../MobileHarness/Agents/Assistant/README.md) |
| `listening_dialogs` 表（新目录 `Storage/Database/ListeningDialogs/` 已获批准） | [ListeningDialogs](../../../MobileHarness/Storage/Database/ListeningDialogs/README.md) |
| 决定与理由 | [ADR 0221](../../adr/0221-listening-mode-state.md) |

与最初草案相比的实际取舍：

- `listening_dialogs` 用 `session_id` 而非 `conversation_id`，没有 episode 关闭记录；episode 由首条与末条记录隐含。
- 没有新增 PlatformKit 接口：回声消除能力沿用采集代际已有的 `supportsFullDuplex`。
- `full` 在采集开始前被接受，采集确认不支持时协调器写回 `half` 并报告；已知不支持时直接拒绝。
- 2026-11-23 起默认 `full`：路线不支持回声消除时回退 `half` 并报告原因，之后路线重新支持（如换设备）则自动回到 `full`；用户或模型显式设置的模式不被自动覆盖。会话结束复位为默认 `full`。
- 应用目前没有勿扰设置，因此不存在“勿扰写入 `listening`”；退出判定也没有被宿主持有的情形。
- 错误与安全提示在 `quiet` 下没有特殊处理：`quiet` 只关闭主动播报，Assistant 本来就不会收到 `quiet` 期间的语音。

### 模型进入 quiet 时的生成收尾

真机请求 4D92C3A7-6A0F-4E06-A127-F214817F673F 停在生成中，后续同会话 ASR 投递报 `invalidTransition`。模型控制在生成调用链内执行，进入 quiet 若同步触发普通会话打断，打断又等待这一生成 worker 退出，会形成循环等待。

- 聆听协调器只在宿主进入 quiet 时使用已有会话打断接口。模型控制通过 Assistant worker 发布 quiet 后，只取消该输入已接纳的语音，由原生成轮次记录控制结果并正常收尾。
- Assistant 输出在 quiet 下不接纳新的语音或字幕，后续同会话 ASR 仍走 quiet 退出判定。外部打断保留原有的会话清理语义。
- 聆听测试用模型和语音替身覆盖模型写入 quiet、原轮次结束、后续 ASR 接纳和退出后普通回复。当前契约见 [Assistant 输入](../../../MobileHarness/Agents/Assistant/Input/README.md#listening-and-quiet)和 [Assistant 输出](../../../MobileHarness/Agents/Assistant/Output/README.md)。

### 每次 quiet 的唤醒约定

- Assistant 的 `state.set` 接收仅适用于 `listening=quiet` 的可选 `wakeCondition`。模型可归纳用户的条件，但保留关键词、否定和明确授权要求。缺少特殊条件时沿用默认唤醒规则。
- Assistant 私有 State 只保存当前 quiet 轮次的 `wakeCondition`。任何离开 quiet 的写入清空它，State 分页与 `state.get` 此时显示 null。去除内部宿主写入的唤醒句参数。
- 真机 00:03 的记录显示主模型曾遗漏“除非喊名字”，另一轮 Apple 模型则对“你是谁？”返回 exit，理由却说未获许可。控制资源要求保留“直到”和“除非”条件。具体关键词使用同一个字段内的 `literal:` 格式，由 QuietExitJudge 直接在 ASR 文本中匹配。开放式语义约定使用 Decision 的布尔判定。
- 显式条件优先于普通招呼。原模式恢复后，同一句 ASR 交回普通对话。SQLite 继续保存逐句判定，字面匹配标记为本地规则。Swift 回归覆盖关键词误触、语义输出矛盾、恢复后的 State 清空以及原有默认路由。

### 共用 Decision 模型

- Agent Runtime 为 interrupt 和 quiet 退出共用 Settings 所选的 Decision 服务。保留语义布尔提问和字面匹配、原模式恢复及退出句回交。退出判定失败时保持 quiet。新记录在现有表结构下标为 `local`、`cloud` 或 `literal`。
- Settings 的 Agent Models 在 Decision 条目上标明 Interrupt 和 Awake 两个场景，继续使用既有选择与保存入口。运行契约见 [Assistant 输入](../../../MobileHarness/Agents/Assistant/Input/README.md#listening-and-quiet)与 [Settings](../../../MobileHarness/UI/Settings/README.md)。

## 待完成

| 项 | 说明 |
| --- | --- |
| 默认聆听模式设置 | 设置页持久化 `half` / `full` 默认值（`quiet` 不作默认），启动时写入 `listening`。当前固定为 `full`。涉及设置模型、Actions 偏好服务、ApplicationControl 与设置页，需单独计划。 |
| 勿扰联动 | 设计勿扰来源后，开启时宿主写 `quiet` 并禁止判定通道退出。 |
| 判定准确率实验 | 退出判定已有[历史评估](../../validation/Quiet-Exit-Evaluation.md)和[新版提示评估](../../validation/Quiet-Exit-Decision-2026-11-25.md)。未完成：进入语句判定、真实 ASR 文本。`experiments/assistant/assistant-evaluation.json` 的系统提示快照仍含旧 `quiet` 变量。 |
| 名字唤醒 | 名字成为状态机的一部分后再做匹配；当前任何称呼都可唤醒。 |
| 真机验收 | 全双工回声消除与打断、半双工闸门、`quiet` 误唤醒与漏唤醒、Apple 系统模型与已下载本地模型的实际延迟。未在真机或真实模型上运行。 |

## 验收

- 已通过自动化测试（见 [验证记录](../../validation/Validation-History.md)）：枚举校验、Trigger 注册与不重入、处理器拒绝不发布、`quiet` 路由、`full` 能力检查、历史判定路径的降级与超时、新句取代、连续失败保持 `quiet`、退出恢复进入前模式、会话结束复位、`listening_dialogs` 存取与容量淘汰。
- 实验归 `experiments/`，不放入 Tests；真机验收单独记录，缺失时不得描述为已通过。
