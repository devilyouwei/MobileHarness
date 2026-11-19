# 全双工播放期间的语音接纳优化

日期：2026-11-16。状态：第一阶段及 ASR 硬冷却已实现，18 个专项测试和五个 iOS 模拟器构建目标通过；完整检查存在其他失败，详见[验证记录](../../validation/Full-Duplex-Playback-Admission.md)。真机声学验收与第二、三阶段实验未完成，整份计划保留于 requirements。

## 本轮实施修订：硬冷却与播放接纳

用户确认第一阶段与 ASR 冷却一并进入 workflow。本轮实现播放起声增量（概率 +0.15、窗口 +2，上限仍 0.95/16）、首播 250 ms 保护、结束后 200 ms 严格起声、完整 ASR 完成后 250 ms 硬冷却。两个保护窗口都丢弃未接纳音频，不缓存补识别；已有用户语句不受起播保护影响。底层麦克风/AEC/播放图持续运行。第二、三阶段依赖实机基线的自适应噪声、降音量和新语义特征仍为后续实验，不直接加入未验证规则。

冷却从完整 recognitionTurn.finish 返回时起计，空结果同样冷却；12 秒模型内部切块不触发。重置 VAD、前滚及重采样/增强缓存，按原始 capturedAt 同时拦截原始 PCM、已生成的 DSP 输出和排队旧包。以至多 32 ms 的处理片段保守丢弃跨保护边界的片段，因此最多增加一个片段的等待，不补送被保护的样本。首次采集及显式停止/代际替换清除门限。

播放事实使用原生首块 schedule 后回调的单调时间；回调产生至多一个被播放生命周期加入的发布任务，结束等待开始通知完成后发布配对终态。Assistant 保留最多 32 个播放区间，400 ms 内同会话片段共用 burst 起点；历史淘汰后带 coverage 边界，早于可证明历史的音频拒绝并计数，不将未知旧 PCM 当作静音期。SpeechPerception 通过只读快照查询，保留捕获时间映射，不添加音频事件队列。

修改文件除上表外包含 Agents/AgentHostBindings、Agents/SpeechPerception/VoiceAgentSession 以及 Actions/Speech/Listening/VoiceSessionConnections 的播放回调时间参数；类型与策略放在现有 SpeechBoundaryPolicy.swift，避免新增目录。同步 DeepFilterNet3 文档的“每句不重置缓存”描述：显式 ASR 冷却现在必须清理缓存。DSP 输出切片使用 capture-scoped 严格递增序号，不复用大包序号；回归替身保留真实 Silero 的序号校验。回归覆盖空结果冷却、缓存晚到、起播保护、分片合并、维持门槛及取消隔离；既有合成测试须使用与 capturedAt 一致的时序，不将极速注入音频误当真实时间。

## 目标与范围

用户反馈 assistant 播报时容易把外部声音识别为用户输入，要求规划播放期间动态提高门槛、起播短时不做 ASR 的优化。本计划同时覆盖手机外放残余回声与耳机环境声，具体优先路线待实测确认。保持正常双讲和语音打断，不恢复整段播放期间禁用识别的半双工方案。

成功标准不是减少所有识别次数，而是降低误字幕、误入队和误打断，同时保留低音量用户及“停”“等一下”等短指令。单纯提高 VAD 概率阈值不能判断人声是否对设备说话；旁人/电视中的清晰人声仍可能通过。因此分别记录自身回声、非语音噪声和外部真实人声，不能统称 AEC 故障。

## 当前实现与缺口

- `SpeechPerceptionAgent` 在 capture 启动时快照检测设置，逐帧使用固定 threshold/onsetWindows。默认 0.65、8 个 512 样本窗口（16 kHz 下 256 ms）；允许范围 0.05…0.95、1…16 窗。
- `SpeechBoundaryPolicy` 用同一阈值判断起声与语句中人声/静音。直接全程抬高该值会同时影响尾音、停顿和端点，需拆分起声门槛与已确认语句的维持门槛。
- `speechEndpointActivity.replyActive` 同时表示模型工作、待执行结果或播放；它目前只控制端点的 800/512 ms 静音选择，不能当作实际播放起点。
- `VoiceNativeEffects` 在首块流 PCM 取出后通知 activeChanged(true)，早于 native schedule。`AppleAudioIO.playStream` 已有首块 schedule 后的 onStarted 回调；该事实仍是原生开始/调度观测，不宣称等于扬声器声波到达人耳的时刻。
- PlatformKit 已用同图 Voice Processing 处理采播。Apple 的回声处理能力不等于已验证本环境的误触发率。本阶段不叠加第二套 AEC。
- 可选 DeepFilterNet3 窗口处理首次输出约需积累 400 ms 输入。处理后 PCM 可能晚于起播保护窗口出队，必须按原始采集时间而非消费时间应用保护，防止过期音频补送入 ASR。
- Assistant 的 Decision 在最终 ASR 后才运行，当前保护有效用户输入的规则也可能把误识别成有意义句子的内容入队。只改 Decision 不能解决前面的误字幕。

## 分阶段方案

### 第一阶段：播放事实、起播保护及动态起声门槛

SpeechPerception 自有的播放感知接纳状态放在现有目录内。播放未开始时继续使用用户设置；起播保护窗口只约束新的 ASR 语句，不切断已确认的用户语句，不停止采集、AEC 或降噪处理。

下表全部为实验初值，不是已验证默认值。先以诊断配置固定快照实现，避免一开始增加大量用户滑块。

| 状态 | 起声/ASR 行为 | 初始实验参数 |
| --- | --- | --- |
| 空闲/仅思考 | 现有起声设置，正常 ASR | 默认 0.65、8 窗不变 |
| 首次起播保护 | 保留底层采集，丢弃保护片段，不进入 VAD/ASR 或补送 | 250 ms；对照 0/150/250/350 ms |
| 稳定播放 | 更严格的起声确认，通过后把确认候选及受控前滚送入 ASR | T_on=min(0.95, base+0.15)，N_on=min(16, base+2)，默认对应 0.80/10 窗（320 ms） |
| 用户语句已确认 | 固定本句的维持门槛和端点策略，不能因下一句 TTS 开始再次封口 | 维持阈值沿用本句基础设置；不与更高的 T_on 共用 |
| 播放结束/取消尾部 | 短暂保留较严格起声条件，再回到基础值；已确认用户语句继续 | 200 ms；对照 0/150/250 ms |

起播窗口实施契约：

1. 根据原生开始事实、会话、播放 ID 和单调时间建立窗口；起播前已有用户语句直接继续。模型开始生成、字幕出现或 TTS 合成开始不触发窗口。
2. 窗口内的新语句 PCM 直接丢弃，VAD/ASR 不接收；清理前滚及 DSP 缓存，不在到期时补送。底层原生采集/AEC 保持运行。窗口内开始且结束的短词可能丢失，必须按验收矩阵测量，不能宣称完全保留。
3. 同一 burst 首片触发一次，400 ms 内相邻片段共用首片起点，后续片段不能延长窗口。真正结束后再次起播才重新判断。
4. 没有新增候选 PCM 队列或异步音频任务；原始片段至多 32 ms，处理后片段至多 512 样本。跨边界片段保守丢弃，最大多等待一个片段。
5. 捕获时间在 DSP 前后双重校验；增强开/关、慢消费和排队旧包不能把已屏蔽区间带回识别。
6. 有起声的完整 ASR 收尾后 250 ms 硬冷却，包括识别为空的语句。无起声静音端点及同句最大时长切块不触发。冷却由数据时间判定，无页面计时器；关闭、代际替换、暂停/恢复及失败恢复清除旧门限。

### 第二阶段：环境自适应与误触发归因

第一阶段完成设备 A/B 后再加入，避免同时改变过多变量：

- 在未确认人声、非起播过渡时估计有限时间窗噪声底；对起声候选增加相对能量裕量（如 6–10 dB 的实验范围），不使用一个固定绝对音量覆盖所有手机/耳机。说话时冻结基线，避免用户/回声把噪声底越抬越高；噪声底不是用户身份判断。
- 已确认用户语句可试验轻微降低 assistant 的播放增益，改善后续双讲条件；由 Actions 请求 PlatformKit 的通用增益能力，并在取消/结束/替代时恢复，不能靠视图存活维持。不要把 Apple 的 other-audio ducking API 误当作本应用 TTS 的专用 ducking。
- 如仍主要是自身回声，再评估对齐的播放参考与近端证据；文本相似度只能是诊断/联合特征，不能因用户重复 assistant 的词就直接删除输入。
- 如主要是旁人/电视，独立评估面向设备说话检测、可用声源方向或显式交互模式。现有声源估计不提供说话人身份；不承诺仅调 VAD 或通用降噪可区分旁人与用户。不在本阶段引入声纹采集或新模型依赖。

### 第三阶段：必要的 Decision 协同

保留声学接纳与语义打断判断的分工。前两阶段仍不足时，向 Assistant 提供受信任的播放重叠、声学接纳原因和置信不足标记，帮助区分有效用户输入与不确定语音；不把模型输出的 enqueue/discard 当作声学真值。需重新审查当前“有意义文本覆盖 discard”的规则，不能无差别放宽或静默吞掉有效请求。

## 所有权、接口与生命周期

| 所有者与预期文件 | 变更职责 |
| --- | --- |
| PlatformKit/Audio：AppleAudioIO.swift、现有 Audio 契约 | 提供通用、带身份与单调时间的播放开始/结束事实；说明 schedule/输出延迟边界，不判断用户或起播屏蔽策略 |
| Actions/Speech/Listening：VoiceNativeEffects.swift、VoiceSessionCoordinator.swift、VoiceSessionConnections.swift；必要时 Actions/Support/Contracts | 把当前执行的播放身份和原生事实通过窄端口传出；取消/失败/停止都有配对终态，禁止旧结束覆盖新播放 |
| Agents/Assistant：AssistantSpeechOutput.swift、现有 runtime binding | 保持播放占用查询；区分准备、原生已开始与结束事实，不用 replyActive 代替播放状态 |
| Agents/SpeechPerception：SpeechPerceptionAgent.swift、SpeechBoundaryPolicy.swift、VoiceActivitySegmenter.swift、SpeechPCMPreparation.swift；必要时同目录新增策略文件 | 拥有接纳状态机、起声/维持分离、候选缓冲、捕获时间映射与取消隔离 |
| Agents/AgentRuntime.swift、App/Composition 现有装配 | 注入上述窄端口；不引入 Agents 对 Actions 实现细节或基础模块之间的新依赖 |
| Tests/Agents、Tests/App、必要时 Tests/ModelKit/Speech/VAD | 状态机、实际链路、增强时间对齐、取消及延迟回归 |

不新增目录或模块。若后续需要产品设置，另列 UI/Settings → ApplicationControl → Actions 偏好持久化及恢复计划后实施；逐音频包不读取磁盘。

状态归属于采集会话，不归属于页面。关闭聆听、capture generation 替换、路由重建、中断、失败清理都清除候选与播放窗口，迟到事件按会话/代际/播放身份拒绝。沿现有串行拥有者更新状态，不为每包 PCM 新建 Task；时间窗口按单调时间计算，无页面计时器。播放事实使用最多 32 个区间的只读快照，无事件队列；淘汰携带 coverage 边界，过旧未接纳音频保守拒绝并计数。未知旧音频不能当作已验证静音。

## 验证与发布门槛

先记录原版基线，再比较：A=现有；B=只动态起声；C=动态起声+起播窗口；D=加环境自适应。设备/路线、音量、距离、房间、降噪开关保持可比，参数不得边测边变。首阶段先选择 B/C，不一次叠加 D。

- 自动化：播放开始/首块延迟/失败未出声、连续 TTS 分片不重复保护、跨边界 PCM、已有用户句不被切断、窗口内短词、静音/弱噪声拒绝、真实双讲、基础高阈值上限、旧 stop/取消/重新开启、降噪延迟及缓存溢出。
- 实机矩阵：手机外放和 AirPods；低/中/高音量；安静、风扇、电视/旁人；用户在起播前、起播后 0/100/250/500 ms 和稳定播放时说话；覆盖“停”“等一下”、轻声和长句。分别比较增强开/关，记录实际设备和版本。
- 度量：每 10 分钟无人指令时的误字幕、误入队、误打断次数；短指令召回率；正确识别首字率；用户真实起声至实际停止播放的 P50/P95；ASR 提交等待及端点等待分别计时；CPU、延迟和队列溢出。
- 暂定产品门槛：相对基线误入队/误打断至少降低 70%；每路线至少 30 次短指令的召回不低于 95%；稳定播放的额外接纳 P95 不超过 150 ms，起播窗口内不超过 350 ms。小样本仅作首轮筛选，不能表述为统计保证；绝对端到端打断延迟仍需报告，不能只公布增量。基线过低时报告原始次数，不计算不稳定百分比。
- 不达标时依次缩短保护窗口、降低播放起声增量或关闭该策略；保留原有全双工基线作对照，不通过延长屏蔽期获得表面改善。
- 实施后运行 `./scripts/check.sh` 与 `./scripts/build-ios.sh`。真机声学验收是本计划的完成条件；编译、替身模型与模拟器测试不能替代。

诊断仅记录阶段、阈值、候选持续时间、能量区间、拒绝原因、播放/capture 代际与时延，默认不保存原始音频或文本。附加音频录制需用户明确授权。

## 文档同步与相关依据

实现后更新 PlatformKit/Audio、Actions/Speech（含 Listening）、Agents/Assistant、Agents/SpeechPerception、必要的契约/装配 README 和 `MobileHarness/README.md` 采播流程；执行证据另存 docs/validation。当前源码 README 保持已实现设计，不预写本计划为能力。

本计划细化[聆听恢复计划](../Listening-Interruption-Recovery-Plan.md)中全双工保留要求。对[DeepFilterNet3 接入计划](DeepFilterNet3-Listening-Plan.md)中“播放期间从不 gate 输入”的边界作明确增补：仍不停止底层采集/AEC，但在短时接纳层丢弃新语句音频，并清理降噪缓存；本轮第一阶段已实施该变更。

参考 Apple 官方 [AVAudioEngine Voice Processing](https://developer.apple.com/videos/play/wwdc2019/510/) 与 [Voice Processing 更新](https://developer.apple.com/videos/play/wwdc2023/10235/)。Apple 的 other-audio ducking 控制其他音频，不替代本应用语音接纳策略或真实声学验证。

## 用户调整：删除两个硬屏蔽窗口（2026-11-16）

用户明确要求删除起播250ms保护与ASR完成后250ms冷却。此前计划中这两个窗口及对应PCM拒绝策略不再适用。移除SpeechAdmissionPolicy、两处rejectSpeechPCM调用、抑制计数/状态、仅为冷却注入的时钟，以及播放burst/protected字段；保留有界播放时间事实、200ms播放尾部状态、动态VAD起声阈值、ASR执行期间的现有状态机、完整语句结束时的预处理重置及会话/采集代隔离。没有时间窗导致的额外等待或丢包，也不新增音频队列。

修改SpeechPerceptionAgent/SpeechBoundaryPolicy，更新VoiceTests及SpeechEnhancementWorkflowTests：起播后的首批PCM立即进入VAD；ASR完成后下一个音频片段立即进入VAD；保留增强边界重置、连续语句、播放期间阈值和半双工恢复围栏验证。同步SpeechPerception、Assistant播放事实、Agents、Actions/Listening、总体流程文档；执行相关回归与check.sh/build-ios.sh，实机验收另记。

上述删除已实施，当前技术契约已同步。验证结果见[删除窗口回归记录](../../validation/Full-Duplex-Playback-Admission.md#删除起播与-asr-后硬屏蔽2026-11-16)；本轮不包含真机安装或声学验收。
