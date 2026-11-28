# 起声确认后按能量降低或暂停 Assistant 播报

2026-11-26 记录。全双工首版已实现，生命周期控制迁移的真机验收待完成。

语音识别阶段确认外部语音起声后，SpeechPerception 独立报告这段语音的能量变化。Assistant 对已登记的 `speak` 应用档位；播报尚未登记时保留最新档位，待登记后应用。调节可以在 ASR 最终结果返回前生效。

| 外部语音能量 | Assistant 播报行为 |
| --- | --- |
| 低于第一阈值 | 按原音量播放。从抑制状态回落时恢复原音量。 |
| 达到第一阈值且未超过第二阈值 | 继续播放，适当降低当前回复的音量。从暂停状态回落到这一区间时，以降低后的音量续播。 |
| 超过更高的第二阈值 | 暂停当前 `speak`，保留播放进度和待播内容。能量持续低于暂停退出线并通过恢复缓冲后，从暂停处继续。 |

声学抑制只对当前语音播报生效。暂停期间保持语音采集与识别，其他 Action 可以继续执行。外部声音降至低档并通过恢复缓冲后，仍有效的播报恢复原音量。

Assistant 在正常播报、降低音量和因高能量暂停 `speak` 时，都按现有规则接收和处理 `interrupt` 信号。高能量暂停期间收到有效的 `interrupt` 时，立即进入现有打断流程，对当前对话轮次执行既有的取消、清理和输入交接。打断优先于声学恢复，已取消的 `speak` 随当前轮次结束，后续能量回落只允许仍有效的播报续播。[现有打断契约](../../../MobileHarness/Agents/Assistant/Input/README.md)

## 验收条件

- 未确认起声时维持当前播报。确认起声后，外部语音能量达到第一阈值时，播报降音量并继续。
- 能量进一步超过第二阈值时，播报暂停。能量回落并通过对应恢复缓冲后，从原进度按届时档位续播或恢复音量，即使识别已经出终稿。
- 暂停和恢复期间，识别继续运行，其他 Action 可继续执行。
- 外部语音持续高于第二阈值、`speak` 仍暂停时，提交针对当前轮次的有效 `interrupt` 信号。验证现有打断流程当即启动，按既有契约完成取消、清理和输入交接。随后降低外部语音能量，验证被打断的播报保持结束状态。

初始阈值、防抖窗口及播报增益记录在[语音感知](../../../MobileHarness/Agents/SpeechPerception/README.md#播放状态与连续接纳)与[Assistant 输出](../../../MobileHarness/Agents/Assistant/Output/README.md)。相关的声音接纳与语义打断规划见[全双工播放期间的语音接纳优化](../technical/Full-Duplex-Playback-Admission.md)。

## 首版实施设计

SpeechPerception 在有效采集中对所有已确认起声的语句报告能量变化，包括无播报、播报暂停及半双工路由仍在采集的时段。复用 VAD 音频窗口，以 RMS 换算 dBFS，使用声学窗口防抖，并通过语音活动 Signal 发送能量和语句身份。声学结束立即恢复仍有效的播报，ASR 可继续收尾。初始阈值采用内部默认值，真机按音频路径和降噪配置校准。

Assistant 收到能量事件即更新会话内当前语句的档位，无需先收到起声事件，也无需已有回复。已登记的播报实例立即接收适用的控制，尚无实例时将档位应用于下一次登记的播报。动作侧通过现有 `preparePlayback` 宿主端口登记音频句柄。PlatformKit 使用同一个播放器节点调整自身增益或保留缓冲并暂停，续播复用原进度。控制通知只保留最新值，PCM 沿用有界背压，暂停仍保留 Action 和打断资格。原生有声区间独立于回复的逻辑播放生命周期。打断、取消或替换同一回复后，旧调节不能恢复新片段；关闭采集会解除仍有效播报的抑制。

修改 SpeechPerception 的窗口处理与 SpeechActivity 契约，Assistant 输入／输出与宿主接线，Actions 语音播报入口，以及 PlatformKit 原生音频控制。实现后同步所有者 README 与总体链路。验证覆盖能量档位、首个确认窗口、声学端点先于 ASR 终稿、同回复跨片段、采集代切换、暂停时打断及迟到恢复；真机独立核对外放和实际支持全双工的耳机路由。

工程证据与待做真机验收见[验证记录](../../validation/Full-Duplex-Playback-Admission.md#播报降音量暂停和续播)。

## Gateway 调节与平滑起停

Assistant 保存当前语句的能量档位，以 `speak` 的开始反馈取得 `executionID`。通过独立 Tool 调用可复用的 `Speech.Playback.setVolume(volume, executionID?)`，通过 `ActionControl` 暂停或继续当前实例。自动恢复需要续播时，Assistant 等待该实例的音量 Tool 成功回报，再单独发送继续。音量函数可由其他获授权的工作流调用，接受有限的归一化音量 0…1，未指定执行 ID 时定位同一调用方和会话内的当前播报。音量切换本身不改变暂停状态。每次播放拥有自己的控制器，原生播放确认后回传状态及控制回执。新片段使用自己的执行身份，并应用会话当前语句的能量档位。

中等能量仍可及时降音。高能量持续 6 个 32 ms 窗口后才请求暂停，等待期间保持降音且继续播放。离开高档需连续 5 个窗口，声学结束仍可立即发出恢复请求。PlatformKit 使用约 120 ms 的线性增益过渡，暂停前先淡出到零，恢复时从原位置以零增益起播再淡入。新档位以当前增益为起点，替换正在进行的过渡。语义打断沿用现有即时取消及清理。

修改 Assistant 的播放 Action 调度、Actions 的注册及端点、SpeechPerception 防抖、PlatformKit 播放控制和相应测试。验收覆盖短高能量突发只降音、持续高能量淡出后暂停、能量回落后平滑续播、待暂停时恢复可替换淡出动作、旧句柄或旧序号无效。实际听感与参数仍需真机复测。

## 首版的逐窗 VAD 准入

首版由 `VoiceActivitySegmenter` 为每个窗口提供是否达到当时生效的 VAD 阈值。`SpeechPerceptionAgent` 将该事实随窗口传给能量策略。已确认语句中只有通过 VAD 的窗口可以累计中档或高档；未通过的窗口按静音推进恢复并清零持续高能量计数。保留语句端点、起声确认及播放 Action 的原有契约。回归覆盖同一语句内高能量且 VAD 判为非语音的噪声。

控制契约由[Action 实例生命周期与控制](../technical/Action-Execution-Lifecycle.md#action-实例生命周期与控制)定义。Speech 作为首个支持暂停与继续的执行实例接入。

音量 Tool 单独返回结果。Speech 在 `VoiceSessionCoordinator` 校验执行身份、目标和序号，再更新增益。Assistant 直接处理回包，模型回复截断仍依据该轮实际完成的 Action。工程回归覆盖独立改音量、旧回包无法提前触发续播、暂停期间设置增益后才继续、越权和已结束目标。

## 语音活动事件独立处理

移除 `SpeechActivity` 的起声修订字段。Assistant 独立处理收到的起声、能量和 VAD 进度事件。一条有效的 VAD 进度包含真实窗口的观测时间；已有 64 个窗口的要求由 SpeechPerception 的快照证明，接收方无需看到连续的进度事件。采集代和会话身份用于隔离已结束的输入源，Action 的控制仍绑定执行实例。验收覆盖空闲采集时的能量、缺少起声前序时收到能量、首个事件早于采集开始通知和播报，以及独立的恢复和进度快照。

### 发送端业务顺序

SpeechPerception 按业务发生顺序提交语音活动，包括采集开始、起声候选与确认、能量变化、恢复和采集结束。VAD 进度可在相邻阶段之间发布其采样事实。Gateway 按已注册的 channel 提供有界 FIFO，VAD、ASR、关键词快停与声音定位独立运行。采集关闭或替换后，已停用采集的迟到处理结果停止发布。语音活动、ASR 和关键词的诊断证据在入队后记录。声音定位保留原有的写入与发布顺序，证据写入失败则报告，后续观测继续处理。订阅端按收到的独立事实处理，消息丢失时允许后续事实继续生效。

## 起声确认后的连续声学让声

可信起声开启一次声学观察。观察期间对所有已处理的 PCM 窗计算能量，包括 VAD 判为非语音的窗口。沿用现有档位、窗口防抖、音量 Tool 与播放 Control。VAD 端点与 ASR final 只结束识别。声学档位仍为中或高时保留观察，后续 PCM 降至低档才恢复原音量；识别已结束、档位为低且电平未在累计升档时结束观察。连续的起声可共用尚未结束的观察，直至声学释放。会话或采集关闭、替换和失败沿现有清理路径释放状态。ASR 收尾期间沿用现有有界采集 FIFO，消费恢复后继续判断电平。

SpeechPerception 的 `SpeechBoundaryPolicy.swift`、`VoiceActivitySegmenter.swift` 和 `SpeechPerceptionAgent.swift` 分离逐窗声量和 VAD 判定。Assistant 的 `AssistantChatInput.swift` 与 `AssistantChatWorker.swift` 将识别终态与能量档位独立结算，继续按采集代和执行 ID 隔离。同步 SpeechPerception、Assistant Input 和总体设计，并在现有 Swift 测试中覆盖未起声噪音、起声后非语音高能量、持续高档跨 ASR final、回落恢复及采集结束。ASR 准入与人声隔离另行评估。

## 让声恢复缓冲（2026-11-28）

语音停顿期间保留当前抑制档位。降音后，电平连续处于降音退出线或以下 600 ms 才恢复原音量。暂停后，电平连续处于暂停退出线或以下 1,000 ms 才恢复播放，按当时电平选择降低或正常音量。等待暂停恢复时，中档与低档之间的电平变化可继续累计；达到当前档位的保持电平会清零恢复计时。沿用现有进入门槛、Tool、Control、淡入淡出和采集关闭结算。语义打断即时取消。采用 OBS 侧链降音的 600 ms 释放为交互调参参考，Audacity Auto Duck 的 1 秒短停顿保护为暂停恢复参考；LiveKit 的 2 秒用于等待误打断有无转写。本项目这两个时间用于恢复前的等待，原有约 120 ms 的增益过渡随后执行。[OBS](https://obsproject.com/kb/compressor-filter/) · [Audacity](https://manual.audacityteam.org/man/auto_duck.html) · [LiveKit](https://docs.livekit.io/agents/logic/turns/#false-interruptions)

修改现有 `SpeechBoundaryPolicy.swift` 的 `SpeechEnergyBands`，按已处理 16 kHz PCM 的样本数累积恢复等待，无额外任务或计时器；采集代与语句身份沿用现有边界。同步 SpeechPerception 和总体设计，更新 `VoiceTests.swift` 验证精确时间边界、短暂回落、响度反弹、暂停直接恢复正常音量和 ASR 终稿顺序。
