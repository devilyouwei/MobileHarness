# Speech — 业务函数与执行设计

## 职责与模块关系

拥有播放、聆听与音频检测函数及真实执行。SpeechExecutionEndpoint 提供稳定的窄端口，弱绑定根语音会话；SpeechModule 显式接收播放、聆听、手势与检测能力，不从无关能力推断可用性。生成、策略与原始 PCM 消费属于上游角色。

Gateway 通过注册函数调用本域，Agents 决定请求与策略，App 注入唯一基础能力和根生命周期。本域消费 FunctionContracts 及需要的基础能力，不导入 Agents、Gateway 实现或 App。全部域内源码由 Actions 单一目标编译。

## 目录与文件

| 文件 | 当前职责 |
| --- | --- |
| [ActionNamespaces.swift](../Support/Contracts/ActionNamespaces.swift) | Shared SpeechActions namespace only; callable implementations remain in the domain files below |
| [SpeechExecutionEndpoint.swift](SpeechExecutionEndpoint.swift) | 语音会话的稳定端口与身份校验，弱绑定实际所有者 |
| [SpeechModule.swift](SpeechModule.swift) | 显式绑定播放、聆听、手势和检测能力 |

| 目录 | 责任 |
| --- | --- |
| [Detection](Detection/README.md) | 检测只消费角色已计算的观测值；原始 PCM 订阅属于角色 |
| [Listening](Listening/README.md) | 实际感知注册与模型图属于注入的上游角色；本目录拥有权限、捕获启停、半双工、启动反馈及真实播放屏障 |
| [Playback](#playback) | 播放只消费已经生成的音频句柄，不选择模型或生成语音；借出、真实排空、取消和租约释放均由播放执行拥有 |

[Support](#speech-shared-contracts) 仅维护跨业务能力共用的契约或算法。

## 函数与完成

Speech.Playback.speak 等待音频排空；Speech.Listening.update 接收策略与反馈；内部 Speech.Listening.prepare 保留兼容缓存准备端口（首页不调用），启动根在 ready 前预载音效；内部 Speech.Detection.run 关联请求私有就绪与检测执行。后两者的函数工厂与同类入口同处业务目录，执行服务不定义注册入口。缺少可选能力时保留定义并明确失败。

## 接口与关键技术
| 函数 | 解析与完成 | 静态 timeout |
| --- | --- | --- |
| speak | 只接受 audioID，最多 36 字节且可解析为 ID；调用播放端点并等待它返回 | 300 秒 |
| update | enabled/paused 严格为 true/false；revision 为正 UInt64；可选启动反馈参数 | 90 秒 |

speak 将所有参数解析错误映射为 missingAudio，并在播放前后检查取消。端点契约要求播放排空与音频租约释放；入口不把音频存在或写入设备当作已播放完成。函数没有文本合成参数，也没有播放缓存。

update 拒绝未知键。cue 可选 wake/confirm/cancel/error/soft/save（默认 wake），volume 为有限 0…1（默认 0.85），hapticStyle 可选 light/medium/heavy/rigid/soft（默认 heavy），hapticIntensity 为有限 0…1（默认 1）。解析结果包装为 ListeningFeedback，并连同真实 invocation 交给宿主。

update 的固定使用者是 SpeechPerception；实际 source/session/revision 准入由 Actions 执行端点验证，函数入口不重复解释权限。新启动的反馈与捕获由端点组合，子结果通过父 invocation 的报告端口保存。策略更新不等于每次都播放启动反馈。

[Actions 设计](../README.md) · [公共函数契约](../Support/Contracts/README.md)

## 公开聆听控制

`Speech.Listening.startListening` / `stopListening` 均为无参数有限 Action，拒绝未知键，timeout 为 90 秒。SpeechModule 通过显式 SpeechListeningCapability.setListening 绑定；未绑定能力或不支持控制时抛出 listeningUnavailable。SpeechExecutionEndpoint 校验根会话并调用弱绑定的 VoiceOutputHandling。启停直接取得感知策略并实际应用，不通过 UI 请求或二次 Action 排队。模型不能提交内部 update 的 revision/paused。完成及取消边界见 [Listening](Listening/README.md)。

Assistant 的语音子能力预留并生产 AudioCache 句柄；Speech.Playback.speak 可在生产期间开始读取，接纳不证明已有 PCM。Actions 不选择 TTS 模型或注册合成角色，取消/失败经同一句柄加入生产者与原生播放清理。

<a id="playback"></a>

## 播放执行

[`Playback/`](Playback/) 的 [PlaybackActions.swift](Playback/PlaybackActions.swift) 校验参数并返回实际回执。[SpeechPlayback.swift](Playback/SpeechPlayback.swift) 借出预留的音频句柄，允许 Assistant 并行继续生产 PCM。播放结束等待原生排空，取消加入流清理和租约释放。聆听策略由根语音会话拥有。

<a id="speech-shared-contracts"></a>

## Speech 共享契约

[`Support/`](Support/)

[SpeechCapabilities.swift](Support/SpeechCapabilities.swift) 定义播放和聆听端口。内部策略用 `updateListening` 应用，公开意图用 `setListening` 提交，不接受 revision 或 paused。未提供公开控制时抛出 `listeningUnavailable`。[SpeechTypes.swift](../Support/Contracts/SpeechTypes.swift) 定义语音错误与反馈值。
