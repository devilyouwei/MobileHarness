# 语音打断后重新聆听验证

日期：2026-11-05。对应[修复计划](../requirements/Listening-Interruption-Recovery-Plan.md)。

## 故障与边界

用户报告 Assistant 播放语音时长按关闭，再长按开启只响提示音，不录音、不显示光效，首页停留“稍等片刻”且灵动岛持续 loading。源码中新会话能打开感知捕获但因 paused 跳过原生麦克风，随后仍播放启动反馈，与该现象一致。

实际定位的竞态位于 Agents/Support/OutputGateway：cancelCalls 设置 producer 取消围栏并加入真实播放清理；此时到达的 ReplyActivity 空闲快照被视为新执行而取消，已经进入直接投递的同类事实也可能被取消。生产者已发布终态但接收者保留旧占用，后续显式启听仍 paused。

修复只让类型化 ReplyActivity 穿过执行取消围栏并保留在途投递；不改变网关关闭、角色/会话鉴权、消息权限、接收者 revision/incarnation 和用户关闭许可，不跳过播放停止或重新发起模型工作。

## 自动化证据

使用真实 Assistant/SpeechPerception 注册、生产者绑定、OutputGateway、InputGateway、ChannelScheduler 与聆听策略；播放清理为可控替身，模型未推理。

- 旧实现：`interruptedReplyPublishesIdleDuringPlaybackCleanupAndListeningCanRestart` 实际运行失败，6 个断言失败：取消期间空闲事实未释放 paused，随后连续五次显式启听均仍 paused。退出码 1；不是超时或编译失败。原始本机日志 `/tmp/mobileharness-listening-recovery-before.log`。
- 首轮修复：同一测试通过，退出码 0；本机日志 `/tmp/mobileharness-listening-recovery-after.log`。
- 扩展用例同时覆盖取消开始前已进入投递、清理过程中才提交的空闲事实；核对普通播放及合成请求依旧取消、旧 revision 无法恢复占用、关闭许可保持关闭以及五次重开感知捕获。

初次本地定向构建使用 Command Line Tools，因缺少 Metal 编译器失败；后续明确使用已安装完整 Xcode。测试源码初次编译的参数顺序和跨目标 path 类型问题已修正，不将这些尝试计为运行通过。

## 最终检查

- 定向回归：5 个测试（其中两个参数化测试各有 2 个分支）全部通过，退出码 0；包含新增打断恢复、显式关闭、多个回复来源占用合并及实际 Gateway 执行取消。日志 `/tmp/mobileharness-listening-recovery-focused.log`。
- `./scripts/check.sh`：退出码 0。模块边界检查、6 项 Python 测试、严格 Swift 格式检查、全部 Swift 测试及项目/plist 检查通过。其中通用 IntegrationTests 为 1024 项，独立运行时阶段为 225 项（206.653 秒）；其余测试目标同样通过。日志 `/tmp/mobileharness-listening-recovery-check.log`。
- `./scripts/build-ios.sh`：退出码 0。MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个模拟器构建均成功；应用内 Agent/Skill 与原生 Live Activity 资源校验通过。日志 `/tmp/mobileharness-listening-recovery-ios.log`。
- `git diff --check` 和新增计划/验证记录的本地链接检查通过。

以上在现有工作区上完成，保留原有未提交改动。构建中的既有警告不作为失败，也不作为真实设备验收证据。

## 真机待验

未执行真实模型、iPhone 麦克风、原生光效与灵动岛验收，未安装到用户设备。

1. 播放 Assistant 回复期间长按关闭，立即再开，以及等待停止后再开；每种至少五次。
2. 确认关闭后没有录音，开启后出现光效和实际录音，新语音可以进入下一轮回复。
3. 确认首页退出“稍等片刻”，灵动岛不残留已取消回复的 loading。
4. 分别覆盖多句回复、多个角色仍有合法占用、蓝牙/耳机路由及系统音频中断；记录设备/iOS/路由与模型版本。

自动化通过与模拟器构建不能代替以上设备验收。临时日志路径不作为持久附件，本报告保存运行结论与证据范围。

## 2026-11-05 Agent 自有字幕与人声起点

SpeechPerception确认新VAD轮次后、首段ASR前显式开启自己的空字幕；Assistant消费既有speaking控制事件，经内部Display Action clearReply清自己的槽，不请求LLM、不占正式FIFO。各自正常结束及停止／恢复聆听保留文本。根失效显式清理，不依赖麦克风布尔状态间接清理。

Actions分离字幕槽与围栏：clearReply带可选replyInputID冻结旧请求，旧请求续轮不能复活字幕；迟到清理不能删除已经建立的新请求，较早排队输入仍可用新请求身份回复。移除UI回复结束清理、350ms到期淡出和识别换轮时清双方字幕。ASR失败封口保留已有文字；ModelKit及数据库结构未修改。

定向日志 /tmp/caption-ownership-focus-pass.log：ASR首段前空字幕、最终文本唯一递交、开口清理只发Assistant Action且模型供应器不得被调用、重复事件单次清理、独立槽、旧续轮／迟到清理、完成后保留通过。首次测试宏不能直接断言mutating成员，改用捕获局部的辅助函数；旧ASR夹具断言“不发送空字幕”已改为新声起点先发送空字幕。首轮完整检查原生阶段因机械臂测试夹具未注册新增内部Action产生11项missingHandler，补齐对应夹具；随后完整检查主集成1024项、独立原生225项通过（/tmp/caption-ownership-check-final.log）。最后补充停止聆听保留、UI槽清理API语义命名及根失效用例，最终完整检查结果在下文续记。

以上均为本机自动化／替身识别与模型断言，不是新的真实ASR、真实模型或真机交互验收。本轮未安装真机，设备仍为前次2026110501版本。最终iOS构建和未执行范围分别记录。

最终完整检查 ./scripts/check.sh 退出0（/tmp/caption-ownership-check-complete.log）：1024项主集成、225项独立原生测试以及其余包测试、Python／模块边界／Swift格式／plist检查通过；停止／恢复聆听保留两个槽、根失效清理用例通过。当前源码随后完成 ./scripts/build-ios.sh 四目标构建，退出0（/tmp/caption-ownership-ios.log），应用Agent/Skill与Live Activity资源校验通过。git diff --check通过。未运行新的真实模型／ASR或安装真机；不将构建、替身语音流和本机原生测试视为真机语音体验验收。

## 2026-11-14 结束聆听清空双方字幕

- ConversationState 在聆听关闭时重置双方字幕、定稿、等待和回复透明度；重新开启不恢复旧文本。同步 UI 技术说明及 UI/AppWorkflow 的开关断言。
- `./scripts/build-ios.sh`：退出码 0，四个构建目标均 BUILD SUCCEEDED（模拟器构建，不代表真机验收）。
- `./scripts/check.sh`：边界检查、7 项 Python 测试、格式检查及 Swift 编译通过。初轮字幕开关新回归通过；两项 HomeEffects 旧保留断言失败后已按新需求修订。另有 InputDecision 两项、NexArm 跟踪一项、Web 注入声明一项失败。AppWorkflow 测试子进程约两分钟没有新输出后终止，完整检查不可视为通过。
- 尚未进行真机长按／视觉验收。
- 后续原生阶段 228 项测试通过，plist 检查通过；check.sh 最终退出码 1。修订后通过完整 Xcode 的 `swift test --filter 'listeningToggleClearsBothCaptionsAndReopensEmpty|replyEndRetainsCaptionsUntilTheirOwnerClearsOrSessionCloses|noticeVisibilityRestoresRetainedBottomCaptionsAndSleepClearsBoth'`，三项定向回归全部通过（退出码 0）。`git diff --check` 通过。

## 2026-11-15 AirPods waking up 修复验证

修复范围：蓝牙 HFP 跳过系统 AEC 的 default 模式探测，保留 voiceChat/实际 voice processing 能力确认；首 PCM 等待默认 10 秒，超时显式失败并清理；首帧前绑定原生中断/媒体服务重置观察。未改变业务聆听许可与半双工屏障。

- `./scripts/build-ios.sh`：五个目标均 BUILD SUCCEEDED，主应用资源校验通过。
- `./scripts/check.sh`：架构边界、8 个 Python 测试、Swift 格式检查通过；全量 Swift 测试出现 InputDecision、NexArmAim 和 Writer/Web 配置相关失败，不能视为全量通过。日志 `/tmp/mobileharness-airpods-check.log`；构建日志 `/tmp/mobileharness-airpods-build.log`。
- 全量运行中的新增蓝牙选择（启用/不启用）、无 PCM 超时、已有终态优先，以及原有首帧取消/失败测试通过。
- 真机未执行：连接 AirPods 后长按开启，确认提示音、退出 waking up、真实转写；重复关闭/开启五次；在启动和运行期间拔插耳机；无首帧应报错退出且之后可以重新开启。静态发现的反复模式配置与无限首帧等待是修复依据，不宣称已在用户设备复现或完成验收。
- 独立定向复跑 `swift test --skip-build --filter 'audioCaptureReadiness|bluetoothCapture|echoCancellation|spatialNative|audioRouteConfiguration'`：16 项测试全部通过，退出码 0，日志 `/tmp/mobileharness-airpods-targeted.log`。
- 全量检查的 AppWorkflow 测试在配置错误后持续无进展，已人工终止该测试子进程；因此该阶段包含中断，不能将其余测试通过当作完整验收。
- 检查脚本最终退出码 1；后续原生阶段的 228 项测试通过（另有 1 项套件测试通过），plist 校验通过。`git diff --check` 通过。前述失败与人工中断仍使全量检查不通过。

### 23:00 真机超时反馈后的引擎配置失效处理

用户截图显示 platform.audio/startCapture timedOut，用户报告断开 AirPods 即恢复；这证明上一次首帧超时保护不等于实机修复。静态复查发现遗漏 AVAudioEngineConfigurationChange，无法处理同一设备采样率/声道变化造成的引擎停止。此次增加采集代配置门和限定引擎实例的通知，首帧前最多重建一次图/源并重新获取格式，首帧后终止旧源进入既有恢复流程；不将超时作为无限重试依据。

- `./scripts/build-ios.sh`：五目标成功，日志 `/tmp/mobileharness-airpods-engine-build.log`。
- 首轮 check 因新增测试直接在 #expect 中调用 mutating 方法触发宏编译限制而失败，已将调用结果保存后断言。
- 修正后 `swift test --filter 'captureConfiguration|captureStartup|audioCaptureReadiness|bluetoothCapture|echoCancellation|spatialNative|audioRouteConfiguration'`：19 项测试通过，退出码 0。日志 `/tmp/mobileharness-airpods-engine-targeted.log`。
- 真机仍待复验：AirPods 已连接启动、连接/断开切换、不同外接麦克风以及重复开关；这些自动化只证明通知门/预算/失败契约，不证明用户设备已恢复。Apple 对引擎配置变化的说明：https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange 。
- 最终 `./scripts/check.sh`：架构边界、8 项 Python、格式检查通过；新增引擎配置回归在全量中通过，但 InputDecision、NexArmAim、Writer/Web 测试失败。AppWorkflow 在缺失 injected Action declarations 等错误后持续不推进，终止本次脚本及其测试子进程，因此后续原生阶段未执行，不能称全量通过。日志 `/tmp/mobileharness-airpods-engine-check-final.log`。最终 `git diff --check` 通过。

### 本轮真机安装

按用户要求以 MobileHarness/Debug 构建至 DeviceDerivedData，使用主应用现有开发团队的命令行覆盖完成 App 与 Live Activity 扩展签名，不修改本地或仓库签名设置。真机构建成功；Agent/Skill（73 项）、Live Activity 和中英文资源校验通过。devicectl 已确认将 dev.mobileharness.app 安装至连接的 iPhone 17 Pro。安装成功不代表 AirPods 采集已通过实机验收；需用户连接耳机复测。构建日志 `/tmp/mobileharness-airpods-device-build.log`。

### 2026-11-16 配置通知复核与保留 I/O 单元

23:55/00:00 用户截图确认 capture.root.open 约2秒 configurationChanged，preparation成功，前版真机修复未成立。用户配合再次复现，但 devicectl stdout 无 OSLog；系统 log collect 需要 root，sudo 无免交互授权，未取得统一日志，不能声称已捕获原生停机原因。

修正为容量1通知流+单个 actor 观察任务，复核实际运行状态与格式再退役。启动重试保留 I/O 和已启用 AEC，只重接格式相关节点/tap；停止取消并加入观察任务。MH_AUDIO_TRACE=1 可输出无内容的格式/运行/首帧事实。

20项定向音频测试通过（`/tmp/mobileharness-airpods-facts-tests.log`）。真机构建通过并已安装至 iPhone 17 Pro，以 MH_AUDIO_TRACE=1 启动控制台等待用户复验（`/tmp/mobileharness-airpods-facts-live.log`）；首轮 iOS 编译发现 actor 跨域调用缺少 await，已修正后重建成功。当前不宣称实机功能通过。

真机定向 stdout 已取得实际时序（AirPods 由用户保持连接）：输入24000Hz/单声道，echo=voiceProcessing；首次 start 返回 running=true，随后配置事实 running=false、格式仍匹配，触发受限重试；保留 I/O 后再次 start 返回 running=true，收到 first PCM received。另有 running=true/matches=true 的通知被正确保留。连续日志已出现7次 first PCM received，未见最终 timedOut；这里只确认原生首帧接纳，不据此推断文字识别或持续交互成功。日志 `/tmp/mobileharness-airpods-facts-live.log`，用户界面/转写确认另记。

本轮最终检查：20项音频定向回归通过，build-ios.sh 五目标通过，Debug真机构建/安装/启动通过；git diff --check通过。check.sh 架构/Python/格式通过，机械臂/输入决策及Writer/Web有失败，AppWorkflow因既有配置缺失等错误后持续停滞，终止脚本与测试子进程，后续原生阶段未执行，整体不通过。日志 `/tmp/mobileharness-airpods-facts-check.log`、`/tmp/mobileharness-airpods-facts-ios.log`。实机 stdout 后续累计9次 first PCM received；仍待用户确认转写与听感。

## 2026-11-16 蓝牙回复期间误识别

用户明确确认 AirPods 已能聆听；随后报告无人说话时回复播放过程中用户字幕出现有意义文字。尚未收到文字是否重复回复的确认，也未记录用户音频，不能断定是回录或ASR噪声误识别。

修复：活动蓝牙输入/输出不以 AEC 启用标记获得全双工许可，MicrophoneCapture 与 captureContext 返回一致的受限能力；复用现有实际播放准入暂停/完成恢复。SpeechPerception 在恢复 ASR/VAD 后以 capturedAt 丢弃恢复时刻之前的原生包，避免播放期间的积压包恢复后被识别。代价是蓝牙回复时不能语音打断；未修改ASR文本或模型，不把本地测试称为真实声学验收。

定向 `swift test --filter 'bluetoothDuplex|bluetoothReplyAdmission|completedASRContinuesWithoutAcknowledgmentAndPlaybackUsesRouteCapability'` 通过：3项参数化测试、8个参数案例，包含播放期间拒绝输入、恢复后新输入接纳/旧输入拒绝及明确关闭保持关闭，日志 `/tmp/mobileharness-airpods-playback-tests.log`。

最终源代码的真机构建通过，已覆盖安装并启动于 iPhone 17 Pro；使用正常启动参数，未开启诊断输出。构建日志 `/tmp/mobileharness-airpods-playback-device-final.log`。用户尚未确认本版本播放期间误字幕是否消失；半双工是明确的行为限制，不称为已测得全双工回声消除修复。

最终 build-ios.sh 五个目标均通过（`/tmp/mobileharness-airpods-playback-ios.log`），新增3项参数化回归在完整检查中亦通过。check.sh 出现 NexArmAim 失败以及 Writer/Web 的 injected Action declarations 配置失败；不视为全量通过。git diff --check通过。

AppWorkflow 在前述失败后持续无进展，终止本轮脚本及测试子进程，退出143；后续原生阶段未执行。完整日志 `/tmp/mobileharness-airpods-playback-check.log`。这不改变定向回归及构建通过的范围，也不代表全仓验收通过。

用户随后回复“好了”，确认当前 AirPods 聆听及回复期间字幕问题已恢复可用，并要求提交修改。这是本次用户实机反馈，不扩展为其他蓝牙设备、全双工或长期稳定性验收；蓝牙播放期间半双工限制保留。

## 2026-11-16 按全双工要求统一 Voice Processing

用户否定蓝牙半双工降级，要求手机和耳机均支持全双工回消/降噪。本轮删除蓝牙类型禁用与系统回消优先分支；两路线统一 playAndRecord/voiceChat 的共享 Voice Processing 采播图，验证输入/输出处理已启用且bypass关闭，配置失败显式退出。保留已实测的I/O复用重试、配置事实复核和首帧期限。仅系统回消标记不再作为当前原生组合处理的成功回执；半双工仅保留给其他明确受限后端。

- 定向16项测试通过，包含未启用处理器拒绝、原始失败传播、首帧/配置失效、回复期间ASR继续与关闭许可保持；日志 `/tmp/mobileharness-full-duplex-tests.log`。
- Debug真机构建通过并安装至iPhone 17 Pro，以 MH_AUDIO_TRACE=1 启动诊断；记录端口类型和处理器/bypass事实，不记录音频内容/名称/UID。日志 `/tmp/mobileharness-full-duplex-device.log`、`/tmp/mobileharness-full-duplex-live.log`。
- Apple Voice Processing 的AEC/NS/AGC能力依据：https://developer.apple.com/videos/play/wwdc2023/10235/ 。启用配置不等于测得实际回声抑制，尤其此前AirPods的误字幕尚未在恢复全双工后验收。
- 本轮尚需手机外放与AirPods分别复验：启动、安静听回复无新增用户字幕、回复中说话可识别/打断。上一版半双工“好了”的用户反馈不能作为本轮全双工声学验收证据。

最终 build-ios.sh 五目标全部通过（`/tmp/mobileharness-full-duplex-ios.log`）；git diff --check通过。完整check.sh架构、8项Python、格式通过，但其他集成/Writer/Web存在失败；AppWorkflow在缺失injected Action declarations等错误后持续停滞，终止本轮脚本和子进程（143），后续原生阶段未运行，不能视为全量通过（`/tmp/mobileharness-full-duplex-check.log`）。截至收尾，新版诊断日志仅确认应用启动，没有新麦克风采集记录，手机和AirPods本轮声学效果均尚未实测。

后续读取本轮真机诊断日志确认：输入/输出均为BluetoothHFP，input/output Voice Processing均为true、bypass=false；首次配置停机后保留I/O重试成功收到首帧。用户仍报告环境噪声疑似误识别，故只确认蓝牙采集和处理器启用，不宣称误字幕已消除；系统麦克风模式与手机内置路线本轮仍未取得实测状态。
