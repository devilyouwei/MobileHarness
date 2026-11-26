# 语音感知到认知的单向通信

实施基线为 `ba188b80`。本方案延续 [Action 执行反馈与续说等待](Action-Execution-Lifecycle.md) 的清理契约，调整 [聆听 Signal](Assistant-Listening-Signals.md) 的职责和方向。

## 目标

Perception Agent 向 Cognition Agent 发布观察事实。单向关系由生产代码中的发布、订阅和调用关系体现。语音链路为 `PlatformKit → SpeechPerception → Gateway → Assistant`，平台能力和应用生命周期继续通过各自的端口接入。Assistant 拥有聆听、唤醒和打断业务状态。

## 实施顺序

### 1. Assistant 使用布尔聆听状态

- 保留 `state.listening` 名称和现有 State 类型机制，默认 `true`。`true` 进入正常对话，采集支持时允许全双工。`false` 保留采集和 ASR，终稿只送给当前选中的 Decision 做唤醒判断。Decision 成功判定唤醒后，由 Assistant 写回 `true`，将唤醒句正常入队一次。同一输入的唤醒判断和打断判断互斥。失败或超时保持 `false`。保留按安静周期和最新输入隔离迟到判断结果的行为。
- 进入 `false` 时，退出当前播报，继续使用既有的宿主或模型轮次取消边界。仅在 `false` 下使用用户约定的可选唤醒条件。统一让 Decision 判断恢复，移除现有 `literal:` 直接恢复的旁路，将精确短语作为唤醒条件交给同一个模型。采集暂停和恢复保留当前对话的布尔值。
- 迁移旧状态时将 `full` 和 `half` 映射为 `true`，将 `quiet` 映射为 `false` 并保留有效唤醒条件。更新 State 读取、控制、首轮初始化和中英文提示词。实际半双工保护由语音会话依据麦克风路由和回声消除能力执行。路由变化由语音会话处理，Assistant 的布尔值保持原意。

### 2. SpeechPerception 直接使用原生播放事实

- PlatformKit 在音频端口提供本 App 的有界、只读播放区间。播放身份及单调时间由原生播放生命周期产生，取消、失败和路由更换结束旧区间。App 装配将端口注入语音感知。
- SpeechPerception 按原始 PCM 采集时刻选取起声门槛与静音端点。只有原生播放期间使用短静音端点。起声保留已有的回声尾部保护、概率增量和连续窗策略。确认起声后继续用基础门槛识别。录音路由的回声消除能力和语音会话的播放准入共同决定物理全双工行为。

### 3. 三条单向语音协议

| 职责 | 现有命名体系下的协议和频道 | 事件 |
| --- | --- | --- |
| VAD 与采集 | `perception.speech.activity.v1`／`perception.speech.activity` | `captureStarted`、`captureStopped`、`onsetStarted`、`onsetCleared`、`onsetConfirmed`、`vadProgress` |
| ASR | `user.input.speech.v1`／`user.input.speech` | `partial` 和 `final`。终态包含完整文本、空结果或失败。Assistant 只订阅终态。 |
| Zipformer | `perception.speech.keyword.v1`／`perception.speech.keyword` | `keywordMatched`，带关键词标识和文字、语句 ID、采集代、起声和命中时间。 |

- 三条协议使用同一个交互会话和采集身份，各自保持频道顺序。当前已接纳快停时，同轮终稿入队并跳过 Decision。终稿先到时结算原语句并按正常输入流程办理。匹配同一活动回复的关键词仍可参与[打断竞态](#快停与模型打断的竞态及执行日志)，迟到起声确认不能重开已结算语句。空转写和失败由 ASR 协议结算。
- Zipformer 在配置启用且采集支持全双工的起声候选上探测。Assistant 拥有打断词表和目标校验，空闲、过期、重复命中归 Assistant 处理。ASR 补判使用现有 Decision 模型，移除 ASR 文本的停止词快捷路径。
- 保持应用控制的 `agent.interruption.v1`。从该频道撤掉 SpeechPerception，撤掉 Assistant 向 SpeechPerception 的两条反向订阅。沿用 Gateway 已有的权限和投递。

### 4. Assistant 根据单向进度完成 64 窗等待

The 64-window post-interruption buffer opens only after the Assistant accepts an interruption against an active reply. An idle ASR final uses ordinary queue admission without starting interruption Decision or opening a buffer.

- SpeechPerception 只报告确实处理过的完整 512 样本窗口。进度带采集代、单调递增序号及最近 64 窗的最早采集时刻。Assistant 在接纳打断时设置观察起点，只有该代的进度证明已有 64 个窗口从起点之后开始，才打开窗口条件。识别同一语句、多个终稿合批和空转写放行继续沿用已有行为。
- 初版按最多 4 个窗口发送一次进度，按采样量计算的批次额外等待最多 3 窗。起声、端点和采集边界按时间顺序封包。同一窗的起声事实先于覆盖该窗的进度。进度走有界内存发布，避免逐窗写入持久化日志。进度缺口只有在后续快照能证明窗口和起声状态完整时才能收敛，否则继续等待并报告异常。队列压力下记录发布失败，保护起声、终稿和采集代事件的顺序。
- 接纳打断后至少等待 64 个实际 VAD 窗口。保留接纳时已经确认的语句和待确认的起声候选。第 64 窗包含在本轮内，窗内开始的候选即使在窗外确认，也等待同一语句 ASR 的终稿、空结果或失败。
- 起声事实和 ASR 终稿携带该起声之前最近 64 个完整窗的最早采集时刻。Assistant 以该事实与打断接纳时刻比较，确定实际 VAD 边界。ASR 与 VAD 跨频道独立到达时，后续语句仍属于普通队列，并与本轮待放行文本分批执行。
- 窗口计满、已接纳起声和 ASR 结算、旧生成和 Action 清理均确认后放行。清理延迟可推迟放行，接纳范围仍以窗口计算。采集代替换使尚在等待中的进度和旧起声失效，新代从第一个有效窗口重新累计。清理失败保持待处理输入并提示异常。

### 5. 切换生产订阅

- 在同一次链路切换中移除 `agent.listening.mode.v1`、`agent.reply.activity.v1`、旧的感知侧打断目标绑定及续说探测请求。Assistant 继续使用现有会话执行清理和执行反馈。
- 通信沿用 Gateway 现有权限和投递契约。UI、本地宿主、Actions 执行反馈和 PlatformKit 观测继续走各自的入口。实现后在 Agents README 记录 Perception 向 Cognition 单向发布事实的设计原则。

### 6. 空转写端点确认已处理的 ASR 事件

ASR 的空转写阈值仍按成功送入模型的 64 个窗计算。若模型已有片段或终稿入队，SpeechPerception 先让当前轮的输出消费者检查这些事件。用 [InferenceSession](../../../MobileHarness/ModelKit/Support/Core/InferenceSession.swift) 的累计事件计数与 [SpeechRecognitionTurn](../../../MobileHarness/Agents/SpeechPerception/SpeechRecognitionTurn.swift) 的已检查计数判断，避免冷启动后积压 PCM 快速补送时把等待读取的片段误判为空。复用原有识别器、输出队列和端点阈值。

### 7. 关键词配置资源

SpeechPerception 的 Zipformer 词表使用 `Resources/Agents/SpeechPerception/ZipformerKeywords.json`，每项维护稳定标签、短语、词元及独立词模式。生产监听与设置诊断读取同一词表。Assistant 的 `Resources/Agents/Assistant/Input/InterruptionKeywords.json` 只包含允许触发打断的标签，角色分别加载和校验自己的资源。两者使用现有 Agents Bundle 加载器与打包验证。

总 README 将单向语音事实保留在听觉链路，将关键词快停和续说窗口归入全双工交互，将模型选择和设置诊断归入 Settings 链路。同步维护流程图与拥有者 README。

## 代码归属与验收

| 所有者 | 修改范围 |
| --- | --- |
| Assistant | State 声明、控制、Input 唤醒和 Decision、Workflow 的打断目标与 64 窗等待 |
| SpeechPerception | 采集、VAD 门槛和端点、Zipformer、语音事件发布 |
| PlatformKit 与语音会话 | 原生播放观测、配对终态、采集准入和装配 |
| ModelKit | InferenceSession 公开累计接纳事件计数，通过现有单消费者流继续投递 |
| Agents 通信适配 | 带来源的语音契约、生产发布与订阅，以及复用 Gateway 的同频道顺序与投递诊断 |

在现有目录内完成。实现后同步整体设计及各所有者 README，清理旧信号、状态枚举、测试替身和陈旧引用。

- Swift 回归覆盖旧状态迁移、安静唤醒句只入队一次、回声消除能力变化、播放时间与延迟 PCM 对齐、空闲命中、旧回复迟到命中、命中和终稿的两种到达顺序、快停去重和 ASR Decision 补判。
- 验证 63／64 窗边界、最后一个窗口出现起声、连续说和 1 秒停顿后的合批、采集代替换、空识别和清理不明。联调时核对生产发布和订阅，确认语音事实的传递方向。
- 运行 `./scripts/check.sh` 和 `./scripts/build-ios.sh`。分别记录 Swift 回归、模拟器构建和真机语音效果。真机比较快停延迟 P95、空闲 Zipformer 推理次数以及批次对放行延迟的影响。

实现验证记录见 [语音感知单向通信验证](../../validation/One-Way-Speech-Perception.md)。

## 快停与模型打断的竞态及执行日志

Assistant 对每个当前回复只接纳一次打断。第一个有效的关键词快停或模型打断先占用既有清理屏障，另一条路径放弃旧目标。ASR 终稿到达不代表打断已经接纳，若同采集代的有效关键词此时才到达，仍可在模型判定期间接纳，已经结算的 ASR 语句不重新开启。

文本输入仍普通入队。Assistant 在提交 Decision 和该决策任务启动模型前核对会话、回复身份与清理屏障。打断接纳后取消同一回复正在进行的分类；已到达的模型布尔结果可以留在日志，迟到或失效的结果不再打断。模型尚未执行或已被取消的失效分类按中性状态展示。既有采集代、续说窗口和清理确认继续管理新轮派发。

Decision 标签用独立来源显示关键词快停和已有模型 Decision。关键词行显示命中的原文、检测耗时与实际打断清理结果，使用独立身份且不填充模型结果或模型请求。成功／失败筛选使用关键词的清理终态。涉及 Assistant 输入与 Decision 队列、执行结算、UI RuntimeLog 与中英文标签。回归覆盖两条路径的先后次序、清理中输入保留、关键词状态筛选及过期分类被跳过。

实现验证见[快停竞态与 Decision 日志](../../validation/One-Way-Speech-Perception.md#快停竞态与-decision-日志)。

模型身份、检测总耗时和推理耗时的契约见 [Zipformer 快停检测与推理耗时](Zipformer-Interrupt.md#快停检测与推理耗时)。
