# 语音打断后的聆听恢复

日期：2026-11-05。

## 问题与目标

用户在 Assistant 语音输出时长按关闭聆听，再长按开启，出现提示音正常但没有光效/录音、首页“稍等片刻”和灵动岛持续 loading；重复开关不能恢复。

取消执行期间，OutputGateway 的 cancellingProducers 会拒绝同一角色/会话的 ReplyActivity；cancelCalls 也会取消已经进入直接执行的该类通知。生产者已经发布空闲快照，接收者却保留占用，导致后续启听策略仍 paused。修复须保留真实执行清理屏障，不伪造空闲、不清空其他角色占用、不通过重启应用恢复。

## 变更范围与实施顺序

1. `Tests/IntegrationTests/VoiceTests.swift`：在真实 Agent/OutputGateway/InputGateway/SpeechPerception 链路中，用受控播放清理 gate 固定“取消尚未完成时到达空闲通知”的时序；先复现失败，再验证取消期间普通执行仍被拒绝，用户关闭保持关闭，重新开启不再 paused，旧占用通知不能覆盖新 revision，重复启停可恢复。
2. `MobileHarness/Agents/Support/OutputGateway.swift`：把类型化 ReplyActivity 作为独立于回复执行取消的生命周期事实；允许其穿过 producer/scope 取消围栏，并在 cancelCalls 加入执行时保留其在途投递。注册身份、会话、通信权限、接收者 revision/incarnation 校验与关闭生命周期不放宽；不扩大普通 Action/Tool 或任意通信权限。
3. 文档同步：更新 `MobileHarness/Agents/Support/README.md` 的取消与事实投递契约，`MobileHarness/Agents/README.md` 的模块生命周期边界，以及 `MobileHarness/README.md` 的回复取消流程；更新 `Tests/IntegrationTests/README.md` 覆盖说明。
4. 执行定向回归、`./scripts/check.sh`、完整 Xcode 可用时的 `./scripts/build-ios.sh`，结果写入 `docs/validation/Listening-Interruption-Recovery.md`。不新增目录、不改动签名、不覆盖无关工作区改动。

## 验收

- 自动化：固定时序复现旧代码失败，修复后通过；覆盖在途事实投递、取消期间新事实、普通执行取消和较旧 revision 拒绝。
- 真机待验：真实 Assistant 语音输出中长按关闭/再开，至少五次；确认录音、光效和后续识别恢复，灵动岛与首页等待状态退出；覆盖立即重开和等待播放清理后重开。自动化替身和模拟器构建不代替真机验收。

## 实施结果

代码、两种取消/投递时序的回归、所属技术文档与总体流程说明已完成；旧实现稳定复现失败，修复后定向及全量检查、四个 iOS 模拟器构建通过。原范围中的真机复验尚未执行，因此本计划保留在 requirements。证据及限制见[验证记录](../validation/Listening-Interruption-Recovery.md)。

## 2026-11-05 字幕按新的人声轮次由 Agent 收尾

按用户确认实施：新一轮VAD确认人声起点才切换字幕，开启麦克风／恢复聆听／ASR或回复结束均不清除上一轮字幕。SpeechPerception在新识别轮次建立后、首段ASR到达前，显式调用setTranscript空文本开启自己的字幕；复用已有speech.phase(speaking)作为发给Assistant的新输入开始控制事件，重复同轮不重新清理。最终文本仍通过speech.final进入正式FIFO；开始事件不请求LLM。

Assistant独立接纳开始事件并经Gateway调用新增内部Display Action UI.Caption.clearReply，不伪装回复开始、不加入正在执行的模型round。按会话／可信发送者incarnation／turn做单调去重，最多32个会话标记，关闭会话释放；满载明确拒绝，不自动覆盖会话。clearReply只操作本来源回复字幕，使用来源序号、识别轮次和已退休的当前回复输入身份拒绝迟到内容及旧请求续轮；新输入对应的新回复、队列中较早委托输入的新回复仍可建立独立身份。现有语音开口打断路径保持。

Actions的ConversationPresentation不再因识别轮次变化清空双方字幕；仅校验会话、轮次和序号。转写更新只更新自己的槽并解除该槽定稿标记，Assistant显式clearReply只清自己的槽并退休旧回复身份。UI HomeEffects删除回复结束时清除转写和350ms回复淡出清理，不按业务阶段决定清理。根失效／会话关闭保留通用整体清理。失败识别仍封口并恢复许可，不再主动抹掉本轮已有转写。

涉及SpeechPerception、Assistant共享Chat执行、Actions/UI/Conversation与相关端口／装配／注册、UI/Conversation及测试README；均使用现有目录，不改通信协议、Gateway调度设计、ModelKit或数据库结构。实现后同步各拥有者及整体技术文档。覆盖新声起点先于ASR、同轮重复／旧代乱序、各槽独立、终态后保留、旧回复无法复活、旧输入新回复仍可呈现、无开始事件LLM请求、取消／根失效，并执行check.sh和build-ios.sh；真实模型／真机验收单独记录。

并发细化：clearReply可附带Assistant代码保存的replyInputID，冻结“开口时要退休的回复请求”，不由模型指定。这样即使旧请求在清理前后续轮，仍不能重新打开字幕；而之后真正开始的新请求不会被迟到的清理误删。UI按来源保留当前退休请求和清理序号（来源最多32个，沿用既有生产者账本），不按识别turn大小禁止旧委托输入发起的新回复。

收尾审计补充：isVoiceActive=false目前也隐式resetCaptions，会使关闭／重建麦克风绕过Agent字幕政策。该联动一并移除，停止聆听只撤下等待指示并改变呈现门，字幕继续保留。UIHome.invalidate显式调用resetCaptions作为真实根生命周期清理；显式会话重置端口仍可整体清理。相应睡眠／根失效回归同步调整。

本节实现及技术README已同步：双字幕由各自Agent在新人声起点显式切换，移除UI轮次／回复到期／聆听开关的交叉清理，保留根生命周期清理。完整自动化与四目标iOS构建通过；夹具修订、证据和未执行的真机验收见 [验证记录](../validation/Listening-Interruption-Recovery.md#2026-11-05-agent-自有字幕与人声起点)。

## 2026-11-14 结束聆听清空字幕

按本次用户要求，替代上文“停止聆听保留字幕”的开关策略：结束聆听立即清空 user 和 assistant 字幕，重新长按开启时保持空白，直到新的识别或回复内容到达。聆听仍启用时的识别、处理和播放阶段切换继续保留原有字幕行为。

实施范围：`UI/Conversation/ConversationState.swift` 在 `isVoiceActive=false` 的统一状态入口调用既有 `resetCaptions`，同时清除定稿、等待和透明度状态；不增加模块、目录或跨模块接口。更新 `Tests/UITests/CaptionPresentationTests.swift` 覆盖关闭、重新开启、重复开关和根失效，更新 `UI/Conversation/README.md` 和 `UI/README.md` 的现行契约。执行 check.sh 和完整 Xcode 下的 build-ios.sh，将实际结果记录到对应验证文档；自动化不替代真机视觉验收。

回归同步范围补充：`Tests/AppWorkflowTests/HomeEffectsTests.swift` 中停止聆听保留字幕的旧断言也改为双方为空；回复结束但聆听仍启用时的保留断言继续保留。

本节代码、文档与三项字幕生命周期回归已完成；定向测试及四目标 iOS 构建通过，全量检查存在其他失败和中断，真机未验。详情见[验证记录](../validation/Listening-Interruption-Recovery.md#2026-11-14-结束聆听清空双方字幕)。

## 2026-11-15 AirPods 启动停留 waking up

静态检查发现 mono 首帧等待无期限，且蓝牙 HFP 已激活后仍尝试 default 系统 AEC 再切回 voiceChat，启动期间反复改变路由配置。修复限定在既有 PlatformKit/Audio：HFP 输入保留 voiceChat，跳过系统 AEC 探测，仍确认 voice processing 实际能力；其他输入保持原顺序。AudioCaptureReadiness 增加默认 10 秒的首帧期限，超时显式失败，取消/成功/原生失败均取消并加入计时子任务，保留首个终态，不制造 PCM 或成功。AppleAudioIO 在等待首帧前绑定原生事件，中断直接结束首帧等待与 PCM；启动自身配置完成后才绑定，避免把自身配置当作用户拔插。

涉及 AppleAudioIO.swift、AudioCaptureContext.swift、AudioCaptureReadiness.swift 和既有 AudioCaptureReadinessTests.swift；更新 Audio/README.md 与测试 README。补充 HFP 选择、首帧超时、成功/失败/取消先到的回归；运行 check.sh 和 build-ios.sh。真机 AirPods 启停/识别/拔插需独立验证，静态原因推断不替代设备复现证据。

本节代码与当前技术文档已同步；16 项音频定向回归和五目标 iOS 构建通过。全量检查有其他测试失败及 AppWorkflow 阶段中断，AirPods 真机复验仍待执行；结果见[验证记录](../validation/Listening-Interruption-Recovery.md#2026-11-15-airpods-waking-up-修复验证)。

### 23:00 真机反馈后的引擎配置失效修复

用户截图确认 AirPods 首帧 timedOut，断开耳机恢复正常；上一轮并未解决真实采集。继续修复遗漏的 AVAudioEngineConfigurationChange：硬件采样率/声道改变会停止引擎但保留旧格式，现有 AVAudioSession 路由 UID 比较无法覆盖同设备格式变化。

在既有 AudioCaptureReadiness.swift 增加单代配置失效门：首帧前配置变化抛出独立错误，首帧后结束 PCM 为 runtimeFailed；失效门可同步关闭，迟到通知不能污染替代代。AppleAudioIO 的 NativePlaybackGraph 在引擎启动前注册限定 engine 实例的通知，在停止前移除并关闭门；通知中不销毁/重建引擎。启动配置变化最多重建一次完整图和 PCM 源，第二次失败明确退出；首帧超时不扩大期限、不盲目重试。每次重建重新读输入格式。保留系统 AEC/voice processing 能力判断，不凭耳机类型伪造全双工。补充配置变化首帧前后、重复通知、停止后通知及单次重建预算回归，更新 Audio/README 和测试说明。检查、构建及真机限制追加到既有验证记录。

23:00 后续修复的代码、回归与当前设计文档已同步。19 项定向音频测试及五目标 iOS 构建通过；完整检查包含其他失败及停滞中断，新增真机验收尚未执行。详见既有验证记录，不将本轮构建/替身测试升级为 AirPods 已修复的设备结论。

### 23:55 configurationChanged 立即失败的修正

用户复验确认上一版立即 configurationChanged；新建图并再次启用 voice processing 的重试可能重复自身配置通知。通知不能无条件作为故障。修改既有通知门：回调只写容量1的合并通知流，NativePlaybackGraph 的单个观察任务在 actor 上、start同步返回后复核 engine.isRunning 和输入采样率/声道，只有停机或实际格式不匹配才退役采集。停止先失效代际并取消观察任务，旧任务即使迟到也不能触碰替代图；任务只做无悬挂的 actor 事实采样，不在通知线程销毁引擎。

启动重试保留已配置的 I/O 引擎，不再次启用已经生效的 voice processing；重新安装 tap/连接并获取格式，避免 reset→重新启用→再次配置变化的循环。保持单次预算和10秒首帧期限。增加通过环境变量 MH_AUDIO_TRACE=1 开启的无音频内容/设备标识诊断 stdout（准备、启动返回、配置通知事实、首帧完成），用于当前真机复验，默认关闭。补充正常运行且格式一致不退役、停机/格式改变才退役及旧通知隔离回归。此前替身测试直接把每个通知设成失败，未覆盖真实启动时序；此次结果须由真机复验补足。

2026-11-16 本节已实施并安装：20项音频定向回归、五目标iOS和真机构建通过；用户保持AirPods连接时，诊断日志确认首次引擎停机后保留I/O重试能接纳首帧，累计9次成功。完整检查仍有其他失败和中断，转写/听感待用户确认。证据与本轮未取得系统统一日志的限制均记录于既有验证文档。

## 2026-11-16 AirPods 回复播放期间的误识别

用户已确认 AirPods 可以聆听，但无人说话时回复播放期间出现有意义的用户字幕。代码把 voiceProcessing/systemInput 启用直接等同于 supportsFullDuplex，蓝牙路径在实际回复播放时仍持续送入 VAD/ASR。尚无音频内容证据区分残余回声与噪声误识别，不将生成句子当作用户确实说话的证据。

本轮采用明确受限的蓝牙采集能力：活动输入或输出为蓝牙音频时，保留实际 AEC 标记但 supportsFullDuplex=false；沿用既有播放准入暂停识别和播放drain后恢复，不停掉已修复的原生采集图。代价为蓝牙回复期间不能语音打断。其他路线的既有能力判断不变。PlatformKit/AudioCaptureContext.swift拥有可测试的原生路线能力选择，AppleAudioIO 同时将结果写入 MicrophoneCapture 和 captureContext，保证感知与执行双方一致。现有 VoiceTests 的播放/恢复回归增加真实蓝牙选择映射，确认播放期间音频被拒绝、结束后可识别且用户关闭不被恢复覆盖。更新 Audio README 与 Listening README 说明能力限制，验证结果记入现有记录。不改ASR模型、不凭文本内容过滤用户话语。

恢复边界补充：原生队列可能仍含播放期间捕获的包，仅按处理时 recognitionSuspended 判断会在恢复后接纳旧音频。SpeechPerception 保存恢复完成的单调时刻，在 consumeMicrophone 依据 frame.capturedAt 拒绝此前的包；新采集代清除该门限。恢复时重置ASR/VAD后才设置门限，保持关闭/新播放准入优先。涉及 SpeechPerceptionAgent.swift、SpeechPerceptionMicrophone.swift 与角色 README；既有播放回归追加迟到旧包拒绝和新包接纳断言。

本节蓝牙半双工能力选择、恢复时间门限、相关README与回归已实现。3项参数化测试（8个案例）单独及全量中通过，五目标iOS和最终真机构建通过，已安装启动。尚未取得用户对新版播放期间字幕/恢复识别的确认；仍不宣称确定声学根因或完成实机验收。

用户已反馈“好了”，确认本轮 AirPods 修正版可用。保留蓝牙半双工限制以及全量检查其他失败记录；本计划其他历史验收事项不因本次反馈自动结项。

## 2026-11-16 恢复手机与耳机全双工及统一语音处理

用户明确要求全双工，撤销上一节蓝牙半双工方案。单声道对话统一使用 playAndRecord/voiceChat + AVAudioEngine Voice Processing（Apple提供AEC/NS/AGC）；删除仅系统回消输入的优先探测与蓝牙分类禁用全双工逻辑，不叠加额外软件回消。准备必须确认输入/输出VoiceProcessing均启用且bypass=false，否则明确抛错并清理，不吞错降级。现有公开 EchoCancellation.systemInput 值仍表示该能力事实，当前原生对话不再选择此分支。

AppleAudioIO保留同图采播、首帧就绪、配置通知事实复核和一次保留I/O重试；启动后、首帧后、播放提交前/原生路线通知复核实际处理状态。AudioCaptureContext辅助选择只接受已确认VoiceProcessing作为当前原生全双工能力；不依据内置/耳机/蓝牙类别降级。MicrophoneCapture与context使用相同结果，SpeechPerception播放期间继续VAD/ASR，支持语音打断。既有受限后端的队列时间门限保留，但不用于屏蔽全双工播放期间的输入。

变更 AppleAudioIO.swift、AudioCaptureContext.swift、AudioCaptureReadinessTests.swift、VoiceTests.swift；删除已替代选择测试，新增处理未启用/异常传播、有效状态及播放期间真实ASR继续的回归。同步Audio、Listening、SpeechPerception与测试README，保留历史验证原文并追加本轮结果。执行定向、check.sh、build-ios.sh及真机构建/安装；手机外放与AirPods需分别验证无人说话回复时无误字幕、回复中说话可识别打断。构建/布尔回执不等于声学效果已验收。

文档核对补充：PlatformKit 根README含旧系统回消优先/失败受限描述，随实现改为组合VoiceProcessing必需且失败明确退出；总体README的播放流程同步说明手机/耳机按已确认的组合处理能力全双工，不改变模块边界或生命周期所有权。

本节代码与技术README已同步；16项定向测试、五目标iOS及真机构建通过，已安装启动。完整检查其他失败/停滞记录保留；手机和AirPods分别全双工无误字幕、双讲打断的实机验收仍待完成。蓝牙半双工不再是本项目修复方案。
