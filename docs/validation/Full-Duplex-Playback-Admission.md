# 全双工播放保护与 ASR 冷却验证

日期：2026-11-16。范围见[需求与方案](../requirements/technical/Full-Duplex-Playback-Admission.md)。

## 实施行为

- 起播 250 ms 内未确认语句的 PCM 丢弃；连续 400 ms 内的播报片段不重复开启窗口。
- 播放及结束后 200 ms 的起声概率较基础值提高 0.15，起声窗数增加 2，保持 0.95/16 的上限；已确认语句仍使用基础概率维持。
- 完整、有起声的 ASR 完成后（包括空文本）硬冷却 250 ms，不缓存补识别。原始和降噪后音频均按原采集时刻检查，冷却清理 VAD/前滚/重采样/增强缓存。12 秒模型内部切块不触发冷却。
- DSP 切片使用独立递增序号，保留 Silero 的输入顺序契约。播放事实按音频 ID 和会话保留最多 32 区间，旧终态不能覆盖新播放。

## 自动化证据与限制

- 首轮专项发现旧“跨完整 ASR 保留增强缓存”用例与硬冷却要求冲突，已更新为验证缓存清理和重新积累；起播测试的异步 ASR 样本数等待也已修正。复测共 14 个测试通过（跨四个测试目标），使用替身 PCM/模型与受控单调时钟。
- 后续增加音频句柄退休后的播放事实、12 秒连续语句和严格 VAD 序号验证。最终专项 `/tmp/asr-workflow-final.log` 退出 0，四个测试目标合计 18 个测试全部通过（1 + 1 + 15 + 1，部分用例参数化）。其中两条旧全双工用例在校正捕获时钟后通过。
- `/tmp/asr-workflow-ios-final.log` 的主应用构建成功，ModelKitRuntime 准备阶段因“Some model objects have changed since the build was started”退出。重试 `/tmp/asr-workflow-ios-retry.log` 退出 0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM 五个目标全部 BUILD SUCCEEDED。
- `./scripts/check.sh` 首次因新增双闭包的 Swift 格式规则退出，已修正并重跑。边界脚本、8 个 Python 测试和格式检查通过。后续全量测试中两条旧全双工用例立即开始下一句，与硬冷却冲突，等待 300 ms 后仍发现旧替身的 PCM timestamp 与 capturedAt 不一致；已改为受控采集时钟，句内时间连续、句间推进 304 ms，再验证无需确认继续聆听，纳入最终专项。
- 完整检查 `/tmp/asr-workflow-check.log` 退出 1：另有 D3 输入决策、机械臂跟踪、Writer/Web 注入声明、模型列表预期等失败；AppWorkflowTests 长时间持续无新进展，人工终止本次测试子进程。原生阶段共 228 个测试，其中 soundSourceSlowSubscriberDoesNotBlockFollowingDirections 报 Timed out waiting for sound perception，不能记为通过；plist 校验通过。未修改这些范围外的行为以迎合检查。
- 工作区存在并行运行的其他 SwiftPM 检查，最终专项与原生阶段曾等待共享构建锁；未停止其他任务，也未将其结果作为本次证据。
- `git diff --check` 与新增方案/验证文档的相对链接检查通过。

## 真机声学验收

### 2026-11-16 真机安装

按用户要求，使用现有开发团队签名构建当前工作区 MobileHarness Debug iPhoneOS，构建通过（`/tmp/asr-device-build-signed.log`）。首次构建因 Live Activity 扩展缺少团队失败，重试通过命令行复用现有团队，不修改仓库签名配置。严格深层签名、73 项 Agent/Skill 资源、Live Activity 和中英文资源校验通过。已原位覆盖安装到 Youwei’s iPhone 17 Pro，bundle ID `dev.mobileharness.app`，安装回执序号 7204（`/tmp/asr-device-install.log`），未卸载或清除数据。系统启动请求因设备锁屏被拒绝（`/tmp/asr-device-launch.log`，FBS Locked）；安装成功，不代表启动或声学验收通过。

尚未执行。手机外放与 AirPods 分别验证：无人说话的播报、旁人/电视、不同音量、起播窗口内的“停”、稳定播放时打断、紧接下一句、长句跨 12 秒，以及降噪开/关。记录误字幕/误入队/误打断、短指令召回、首字完整性及绝对 P50/P95 打断延迟。

250 ms 硬窗口内开始并结束的用户短词可能被丢弃，这是需实测评估的明确取舍。测试与构建通过不证明真实回声抑制效果，也不证明能区分旁人与用户。参数调优、环境自适应和面向设备说话检测仍按方案后续阶段推进。

## 删除起播与 ASR 后硬屏蔽（2026-11-16）

用户明确删除两个250ms窗口。移除SpeechAdmissionPolicy、raw/DSP后的rejectSpeechPCM、冷却时钟、抑制计数和播放burst/protected字段；不以零阈值保留旧实现。播放事实仍有最多32区间及200ms尾部状态，供动态起声门槛使用。ASR完成后的原有预处理重置、识别状态机和半双工恢复围栏保留。

回归改为验证起播首个512样本立即送入VAD、ASR空结果完成后连续8个32ms片段全部送入VAD，保留ASR实际收到PCM、增强重置、连续12秒切块、播放期间起声门槛及跨会话隔离。旧窗口测试被替换；前面历史记录不再代表当前窗口策略。

- 专项 `/tmp/speech-remove-windows-tests.log` 通过：11 项语音集成测试及 1 项增强设置测试。覆盖首帧接纳、ASR 后立即接纳、连续语句、增强重置、全双工和半双工恢复。测试使用替身音频/识别器，不代表真实模型或真机声学验收。
- `./scripts/build-ios.sh` 退出 0：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM 五个 scheme 全部构建通过，日志 `/tmp/speech-remove-windows-ios.log`。

- `./scripts/check.sh` 退出 1，日志 `/tmp/speech-remove-windows-check.log`。模块边界、8 项 Python 测试、Swift 格式检查通过；IntegrationTests 的 1204 项测试报告 7 个问题，涉及 D3 决策和机械臂跟踪。AppWorkflowTests 报 Writer/Web 缺失 injected Action declarations 及模型列表预期失败后持续无进展，终止本次测试子进程以继续后续阶段，因此该阶段未完整结束。原生阶段 228 项测试中 soundSourceSlowSubscriberDoesNotBlockFollowingDirections 报 1 个问题；plist 校验全部通过。未修改范围外代码来规避失败。
- `git diff --check` 通过；已扫描确认窗口策略、拒绝函数、冷却时钟及抑制计数的 Swift 引用全部移除。未执行本轮真机安装或声学验收。

### 删除窗口后的真机安装（2026-11-16）

按用户要求，当前工作区以现有开发团队签名构建 MobileHarness Debug iPhoneOS，通过构建、深层严格签名及 Agent/Skill、Live Activity、中英文资源校验。已原位安装到 Youwei’s iPhone 17 Pro，安装回执序号 7212；未卸载或清除数据。首次启动因 CoreDevice 连接中断失败，重试成功，系统返回 Launched application。日志为 `/tmp/speech-no-windows-device-build.log`、`/tmp/speech-no-windows-device-install.log`、`/tmp/speech-no-windows-device-launch.log` 和 `/tmp/speech-no-windows-device-launch-retry.log`。安装包含删除两个 250ms 硬屏蔽窗口的修改；启动回执不代表真机声学验收通过。

## 语音链路整理与诊断（2026-11-20）

范围见[需求与方案](../requirements/technical/Full-Duplex-Playback-Admission.md#语音链路复查与整理2026-11-20)。本次不改变接纳语义，不包含任何声学效果结论。

- 代码阅读：采播图在输入/输出节点同时确认 Voice Processing 启用且未旁路，未发现遗漏的节点配置；降噪失败仍按契约显式失败。自身播报或环境声被识别的实际原因需真机基线，本次仅新增 `SpeechOnset` 诊断日志（播放状态、起声门槛、窗口数、窗口 dBFS）。
- 自动化：新增 `speechOnsetPolicyRaisesOnlyTheOnsetGateDuringPlayback`、`audioFrameFloatSamplesRoundTripWithLevel`。带 speech/voice/enhancement/sound/Silero 过滤的专项运行（`/tmp/mh_speech_tests.log`）退出 0，含 123 个测试的主批次、4 个 speechWorkflow／增强用例全部通过。
- `./scripts/check.sh` 的边界脚本、Python 测试、`swift format lint --strict`、plist 校验通过；Swift 测试 1212 项中仅 `assistantInstructionBudgetsKeepCatalogAndSafetyRules` 失败（`photography.utf8.count < 38_000`）。该失败来自工作区内他处对 BasicSkill 指令的未提交修改，不在本次改动范围，未处理。整体退出码因此为 1，不记为通过。
- `./scripts/build-ios.sh` 退出 0（`/tmp/mh_ios.log`）：五个 iOS Simulator 目标均 BUILD SUCCEEDED，资源校验通过。真机验收（手机外放、AirPods、旁人/电视、起播窗口打断等）仍按上文矩阵待执行。

## 打断后等待续说（2026-11-22）

范围见[方案](../requirements/technical/Assistant-Channel-Settlement.md#打断后等待续说2026-11-22)。测试使用替身，不代表真实语音或模型效果。

- 定向 Swift 测试退出 0：4 项测试通过，包含 8 种打断等待场景、3 种发布终态、动态 VAD 端点和 Action 取消结算。第二次请求实际启动时间用于检查至少 800ms，避免依赖测试任务按时唤醒。
- `./scripts/check.sh` 最终退出 0：边界、Python 工具回归、格式检查、普通 Swift 测试和 plist 校验完成；普通批次的 1203 项及串行 LiveRuntimeTests 的 231 项通过。但 NativePresentationTests 日志在 `cameraNativeMetalDrawStopAndLayerHandoff` 开始后没有结束记录，即使脚本退出 0，也不能视该阶段为通过。此前一次检查该测试报告窗口可见性失败；初次检查还有测试时间断言和另一原生测试失败，时间断言已修正。
- `./scripts/build-ios.sh` 退出 0：五个 Simulator scheme 均构建成功，最终 App 的 Agent/Skill、Live Activity 和本地化资源校验通过。
- 真机全双工语音体验与真实模型验收未执行。

### 停播后计时与续说空档

用户反馈停止播放的耗时消耗了续说窗口。本轮改为认领打断立即建立派发屏障，取消清理成功完成后才开始 800ms；最后一个在途语句的 final 入队、空结果或失败收尾后重新计时，再次起声继续阻止派发。VAD 参数不变。

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path . --filter 'interruptedSpeechWaitsForWindowAndFinalAdmission|interruptedSpeechCleanupCannotRearmRetiredWait|publicationSettlementReportsActualRecipients|speechBoundaryUsesCurrentEndpointDuringSilence|fullDuplexInterruptSettlesOldActionAndRetainsQueuedInput'` 退出 0：5 项测试通过，覆盖 10 种等待场景及清理期间暂停/停止两种生命周期退役。使用下一次请求的实际单调时间验证慢清理完成、最后 final、空结果及失败之后至少 800ms；覆盖再次起声、旧语句 ID、合批文本与动态端点。
- `./scripts/check.sh` 退出 0：边界、Python 工具回归、格式与 plist 校验通过；普通 IntegrationTests 的 1204 项和 LiveRuntimeTests 的 231 项通过。本次 NativePresentationTests 的 Camera 测试通过，但日志在 `webNativeLoadsLocalJavaScriptAndCapturesVisiblePixels` 开始后没有结束记录，随后运行另一 suite；不能将该原生界面阶段视为完整通过。日志 `/tmp/mobileharness-interrupt-gap-check.log`。
- `./scripts/build-ios.sh` 退出 0：五个 Simulator scheme 构建及 Agent/Skill、Live Activity、本地化资源校验通过。日志 `/tmp/mobileharness-interrupt-gap-ios.log`。
- `git diff --check` 通过。未执行真实模型或真机语音验收；800ms 之外的用户停顿仍可能触发回复，有限空档不保证任意长停顿都不抢答。

### 续说窗口扩大至 1200ms

在保留清理后计时、起声后的 ASR 等待及原有 VAD 规则的基础上，将打断后和最后语句收尾后的空档均从 800ms 改为 1200ms。

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path . --filter 'interruptedSpeechWaitsForWindowAndFinalAdmission|interruptedSpeechCleanupCannotRearmRetiredWait|speechBoundaryUsesCurrentEndpointDuringSilence|fullDuplexInterruptSettlesOldActionAndRetainsQueuedInput'` 退出 0：4 项测试通过，参数化覆盖无语音、在途语音、续说 final 合批、失败、慢清理及生命周期退役，并以实际派发时间验证至少 1200ms。
- `./scripts/check.sh` 退出 0：边界、格式、工具回归和 plist 检查完成；普通 IntegrationTests 的 1206 项、LiveRuntimeTests 的 231 项通过。但 NativePresentationTests 中 `cameraNativeMetalDrawStopAndLayerHandoff` 报窗口可见性失败，且日志在 Web 原生测试开始后没有该 suite 的结束记录，不能将原生阶段视为通过。日志 `/tmp/mobileharness-interrupt-1200-check.log`。
- `./scripts/build-ios.sh` 退出 0：五个 Simulator scheme 构建成功，App 资源校验通过；`git diff --check` 通过。
- 未执行真实模型或真机语音验收。窗口依赖 VAD 确认起声通知；窗口边界的音频处理延迟竞态未由单纯延长时长解决。

### Decision 最新候选优先

按[需求](../requirements/technical/Assistant-Channel-Settlement.md#decision-最新候选优先2026-11-22)实现 latest-wins：新候选取消旧分类，只推理最新待处理候选；旧候选以 superseded 结算，普通输入不丢弃。原生 worker 仍由 AssistantInputDecision 持有，后继在自己的截止时间内等真实清理结束，不重入；清理等待超时仍明确失败。日志将被替代与失败分开呈现。

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path . --filter 'latestDecision|independentDecisionQueueBoundsAndJoinsCancellation|twoInterruptSignalsForOneReplyCancelOnlyOnceAndKeepBothInputs|supersededDecisionIsNeitherModelSuccessNorFailure|runtimeLogDecisionRetentionSortingAndFiltering'` 退出 0：7 项测试通过。覆盖非即时清理、原生取消、跳过中间候选、旧结果不发信号、输入保留、直接尝试替代/取消、会话关闭、32 条结算容量、等待超时和恢复，以及被替代记录不落入成功或失败筛选。日志 `/tmp/mobileharness-decision-latest-final-targeted.log`。此前本地化符号生成发现大小写键冲突，改为独立标题键后复测通过。
- `./scripts/check.sh` 退出 0：边界、工具回归、格式与 plist 检查通过；普通 IntegrationTests 1209 项、LiveRuntimeTests 232 项通过。但 NativePresentationTests 在 `cameraNativeMetalDrawStopAndLayerHandoff` 开始后没有结束记录，随即开始其他测试运行；不记为原生界面阶段通过。日志 `/tmp/mobileharness-decision-latest-final-check.log`。
- `./scripts/build-ios.sh` 退出 0：五个 Simulator scheme 构建成功，Agent/Skill、Live Activity 和中英本地化资源验证通过。日志 `/tmp/mobileharness-decision-latest-ios.log`。
- `git diff --check` 通过。未执行真实 Laya 推理、真机安装或语音验收；可控替身不证明 CoreAI 原生调用会响应取消。本次不强制终止或卸载在途原生工作，不能声称已修复用户报告的持续 10–30 秒清理不退出。

### 打断后 40 个语音窗口

打断清理完成后，一次性观察 40 个 512 样本的 VAD 窗口；已确认或新确认人声后等待该语句正常端点和 final 实际入队，随后直接放行，不重新等待。第 40 窗存在起声候选时继续判定；清理前音频、旧采集代与旧语句不能释放屏障。采集不可用或 10 秒观察未推进明确报告失败。正常起声与端点参数不变。

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path . --filter 'nativeSpeechReportsVADWindowsWithCaptureTimeAndGeneration|interruptedSpeechWaitsForWindowAndFinalAdmission|interruptedSpeechCleanupCannotRearmRetiredWait|speechVADReportsCandidateAndWindowOffsetAcrossPartialFrames|coldVADAndASRPreserveRecordedPrefixAndJoinLiveAudioInOrder'` 退出 0：5 项测试通过；覆盖 39/40 窗、边界候选确认/消退、提前和清理期间起声、多个语句、空值/投递失败、采集关闭、旧代/旧时间、暂停/停止、部分窗口偏移及原生采集替身到 VAD 的窗口元数据。断言最终放行在 1 秒内，不会额外等待 1200ms。日志 `/tmp/mobileharness-speech-window-targeted.log`。
- `./scripts/check.sh` 退出 0：边界、格式、工具回归和 plist 通过；普通 IntegrationTests 1211 项、LiveRuntimeTests 232 项通过。NativePresentationTests 中 `cameraNativeMetalDrawStopAndLayerHandoff` 报窗口可见性失败，之后 Web 原生测试没有完整 suite 结束记录，不能视为完整通过。日志 `/tmp/mobileharness-speech-window-check.log`。完整检查发生在新增上述 1 秒断言之前，该断言由随后定向测试验证。
- `./scripts/build-ios.sh` 退出 0：五个 Simulator scheme 构建成功，资源检查通过。日志 `/tmp/mobileharness-speech-window-ios.log`。
- 未执行真实模型或真机语音体验验收。窗口按 PlatformKit 提供的 `capturedAt` 判别，原生 VPIO 路径目前使用音频回调时刻而非直接使用硬件帧起点；采集回调延迟及跨清理边界的缓冲区可能影响窗口边界，替身的精确时间戳测试不能证明物理设备上的采集时间精度。

## 打断后按播报进度截断回复

日期 2026-11-26。基线 `46950bb6`。本节记录原有语音截断实现的验证与安装，[现行范围](../requirements/technical/Full-Duplex-Playback-Admission.md#打断后按已完成的-action-重建回复)另行验证。

- 最终 Swift 专项 5 项通过，覆盖 PCM 回执、截止时刻、未播、部分播完、完整播完、迟到回执、生成尚未解析完、SQLite 重读和下一次模型请求正文与标记。语音合成、原生播放回执和聊天模型使用确定性替身。
- `./scripts/check.sh` 在边界检查退出，报告 `Agents/AgentContainer.swift` 的 State Value codec 以及 15 个 Xcode 本地化资源归属问题。这些问题已在[语音单向通信验证](One-Way-Speech-Perception.md#构建与静态检查)中记录。另行运行的变更 Swift 文件严格格式、8 项 Python 工程工具回归、plist 与 diff 检查通过。
- 单独运行普通 Swift 阶段，IntegrationTests 的 1,277 项中报告 4 条失败。两条是 Action 取消状态断言，另两条来自 `toolRoundTripPreservesSessionAndCallID` 的两种返回路径。失败类型与基线验证记录一致，此阶段的播报截断用例通过。
- 串行阶段的 `LiveRuntimeTests` 通过 232 项。`NativePresentationTests` 两项相机测试通过，Metal 交接用例开始后没有该 suite 的结束记录，原生呈现全套验收仍待完成。
- `./scripts/build-ios.sh` 的五个 Simulator scheme 均通过。补充处理生成尚未解析完的尾部后，重新构建 `MobileHarnessSimulator`，94 项 Agent／Skill 资源、Live Activity 和双语资源校验通过。
- 真机语音打断、实际音频与文本边界、真实模型对标记的理解留待独立验收。

2026-11-26，签名版 MobileHarness 0.1.0（2026112605）通过真机构建、严格签名及 App 资源检查，在 iPhone 17 Pro 上从 2026112604 原位更新。安装回执序列为 8152，独立应用清单确认已安装构建号 2026112605。

## 打断后按已完成的 Action 重建回复

日期 2026-11-26，基线 `3d6714fb`。跨轨道回归使用确定性的完成 Signal，覆盖原始入轨顺序、反序回执、失败和取消夹在成功动作间、清理期间成功、零成功动作、重复文本片段、SQLite 重读及下一次模型请求。Function Token 解析回归核对转义和多字节文本的原始范围。

- 定向 Swift 回归 25 项通过。普通 Swift 阶段的 IntegrationTests 运行 1,276 项，报告 16 条失败，其中 4 条来自 Action 取消与 Tool 回传，另 12 条来自四种停词输入。停词与跨轨道结算专项复跑通过。
- `./scripts/check.sh` 在既有 State Value codec 和 Xcode 本地化资源归属检查处退出。变更文件严格格式、8 项 Python 工程工具回归和 `git diff --check` 通过。
- `./scripts/build-ios.sh` 的五个 Simulator scheme、94 项 Agent／Skill 资源、Live Activity 和中英双语资源校验通过。
- 签名版 MobileHarness 0.1.0（2026112606）通过真机构建、严格签名和资源校验，在 iPhone 17 Pro 上从 2026112605 原位更新。安装回执序列为 8160，独立设备清单确认构建号。真机交互和真实模型效果待验收。

## 打断历史的双语提示

2026-11-26。Swift 专项 37 项通过。双语回归核对中英文输入规则与已截断历史使用同一资源标记，普通历史沿用原正文，并覆盖截断落库后下一次模型请求。

`./scripts/check.sh` 在既有 State Value codec 和 Xcode 本地化资源归属检查处退出。变更 Swift 文件的严格格式、8 项 Python 工具检查、plist 检查和 `git diff --check` 通过。

`./scripts/build-ios.sh` 的五个模拟器目标通过，App 的 Agent／Skill、Live Activity 和中英文资源校验通过。

签名版 MobileHarness 0.1.0（2026112607）通过真机构建、严格签名和资源检查，在 iPhone 17 Pro 上从 2026112606 原位更新。安装回执序列为 8168，独立设备清单确认构建号。

## 播报降音量、暂停和续播

Swift 专项 41 项通过。确定性 PCM 回归覆盖已确认起声后的正常、降音及暂停档位、升降阈值的防抖、播报失去有声区间后继续感知、声学恢复早于 ASR 终稿，以及受限路由不发布能量档位。播放控制回归覆盖同一回复跨语音片段保留暂停、新回复隔离，以及关键词和模型打断胜出后拒绝迟到恢复。

`./scripts/build-ios.sh` 的五个模拟器目标通过。最终源码的 App 复编译及 Agent／Skill、Live Activity、中英文本地化打包校验通过。

`./scripts/check.sh` 在既有 State Value codec 和 Xcode 本地化资源归属检查处退出。8 项 Python 工程工具测试、变更 Swift 严格格式、plist 和 `git diff --check` 通过。

### 真机安装

带全双工播报抑制的 MobileHarness 0.1.0（2026112612）通过 iPhoneOS Debug 构建、严格签名及三项资源检查。iPhone 17 Pro 从 2026112611 原位更新，安装回执序列 8208，设备清单确认构建号，系统启动成功。真实路由上的降音、暂停位置、续播听感和阈值仍待实测。

## Gateway 调节与平滑起停

最终 Swift 专项 65 项通过。Gateway 回归保持 `speak` 在途，验证独立的 `Speech.Playback.adjust` 能在另一通道执行并结算。回归覆盖同一回复跨片段继承、旧序号和旧回复拒绝、短促高能量不暂停、持续高能量和释放的缓冲、线性增益插值、有效打断后拒绝恢复。

`./scripts/build-ios.sh` 的五个模拟器目标通过，最终源码的 App 复编译通过，Agent／Skill、Live Activity 与中英文本地化资源校验通过。`./scripts/check.sh` 仍在既有 State Value codec 和 Xcode 本地化资源归属检查处退出。变更 Swift 严格格式、8 项 Python 工具测试、plist 和 `git diff --check` 通过。调整后的暂停缓冲和淡入淡出尚未在真机验收。

### Gateway 调节版真机安装

MobileHarness 0.1.0（2026112613）通过 iPhoneOS Debug 构建、严格签名和三项打包资源检查。iPhone 17 Pro 从 2026112612 原位更新，安装回执序列为 8216，设备应用清单确认构建号，系统启动成功。真机上的暂停缓冲与线性增益过渡仍待听感验证。

### 逐窗 VAD 准入

2026-11-27。7 项 Swift 专项通过。回归在已确认语句内分别注入 VAD 判为语音和非语音的高能量窗口。判为语音的连续高能量窗口触发暂停；同样响的非语音窗口使已降低的播报恢复原音量，未触发暂停。半双工用例未发送档位变化。

`./scripts/build-ios.sh` 的五个模拟器目标及应用资源检查通过。`check.sh` 仍在既有 State Value codec 和 Xcode 本地化资源归属检查处退出。变更 Swift 格式、8 项 Python 工具检查、plist 和 `git diff --check` 通过。本次修正尚未安装到真机。


### ActionCall 和 ActionControl 迁移

2026-11-27。最终 Swift 回归分开运行，共 84 项通过。独立控制的集成回归用替身播放器覆盖暂停后正常继续、暂停时取消、淡出尚未确认时继续取代暂停，并验证同一 `executionID`、跨会话拒绝、旧序号拒绝和唯一执行终态。Assistant 关键词与模型打断用例验证暂停指令绑定播报实例，以及打断后迟到的低能量事件不会续播。扩展回归第一次与 iOS 构建并行运行时，20 ms 的 Gateway Request/Reply 超时用例未观测到已启动处理器。该用例独立复测通过。

`./scripts/build-ios.sh` 的五个模拟器目标通过。最终源码再次构建主 App，Agent／Skill、Live Activity 和中英文本地化资源校验通过。`./scripts/check.sh` 仍在既有 State Value codec 和 Xcode 本地化资源归属检查处退出。8 项 Python 工程工具测试、变更 Swift 严格格式、工程 plist 和 `git diff --check` 通过。替身回归确认控制链路，真机外放和耳机的淡出、暂停位置及续播听感尚待验收。

### 独立音量 Action 与通用生命周期命令

2026-11-27。29 项 Swift 定向回归通过。Gateway 集成用替身播放器验证 `Speech.Playback.setVolume` 可在 `speak` 暂停时独立结算，播放保持暂停，之后可继续或按同一个 `executionID` 单独取消。Assistant 回归验证高档发 `pause`，回落时先发 `setVolume`，收到对应的成功终态后才发无音量参数的 `resume`，语义打断继续拦截迟到的恢复信号。

`./scripts/build-ios.sh` 的五个模拟器目标、App 的 Agent／Skill、Live Activity 以及中英文本地化资源校验通过。`./scripts/check.sh` 仍在既有 State Value codec 和 Xcode 本地化文件归属检查处退出。变更 Swift 严格格式、8 项 Python 工程工具检查、工程 plist 与 `git diff --check` 通过。设备音量和起停听感尚待真机确认。

### 独立语音能量上报与事件接纳

2026-11-27。9 项 Swift 定向回归通过。PCM 替身覆盖空闲采集、半双工仍可采集、真实有声时段切换以及同样响的非语音窗。Assistant 用例先送能量更新，后送采集开始和播报开始，验证能量档位用于新登记的实例。续说用例使用不带进度序号的完整窗口快照，验证接收端按实际采集时刻放行。

`./scripts/build-ios.sh` 的五个模拟器目标及 App 的 Agent／Skill、Live Activity、中英文本地化资源校验通过。`./scripts/check.sh` 在既有 State Value codec 和 Xcode 本地化资源归属检查处退出。8 项 Python 工程工具测试、变更 Swift 严格格式、工程 plist 和 `git diff --check` 通过。真实扬声器与耳机路由上的声音效果待设备验收。

### 语音信道内顺序与跨信道并行

2026-11-27。语音 PCM 替身验证采集开始、起声候选、起声确认、能量变化、恢复和采集结束在 VAD 信道中的入队顺序。发送工作流回归分别阻塞 VAD 和 ASR 信道的第一条消息，验证各自后续消息保持 FIFO。解除 ASR 阻塞时，ASR 终稿在 VAD 信道仍被阻塞的情况下独立提交，关键词信道也独立提交。

12 项 Swift 定向测试通过。8 项 Python 工程工具测试、变更 Swift 严格格式、工程 plist 与 `git diff --check` 通过。`./scripts/check.sh` 仍在既有的 State Value codec 和 Xcode 本地化资源归属检查处退出。

主 App 模拟器复编译通过，Agent／Skill、Live Activity 和中英文本地化资源校验通过。

### Gateway 定向请求与发布顺序回归

2026-11-27。定向场景阻塞一笔 Send，在同一信道和目标上发出第二笔 Send 与一个类型化 Request。第二笔 Send 可确认接收，Request 可独立取得回复。超时用例验证接收端能读取截止时间，取消后 Gateway 回收容量。发布场景交错两个发布者，验证同一订阅者保持信道入队顺序、慢订阅者与其他订阅者隔离。语音用例分别阻塞 VAD 和 ASR，验证关键词快停仍可独立提交。Assistant 用例阻塞 ActionCall，验证 ActionControl 能送达，依赖前序 ActionCall 的 `wait` 仍保持业务顺序。

341 项 Swift 扩展回归通过，Send 和类型化 Request 的两项计时回归分开通过。回归也验证了接收端的原始错误、同函数 Tool 并发、合法轮次内的 Tool 回执关联、播报控制和打断清理。`./scripts/check.sh` 在既有 State Value codec 和 Xcode 中文资源归属检查处退出。变更 Swift 严格格式、8 项 Python 工程工具测试、工程 plist 和 `git diff --check` 通过。未测量吞吐量或设备听感。

`./scripts/build-ios.sh` 的五个模拟器目标通过。最终超时收尾代码完成后，主 App 模拟器复编译及 Agent／Skill、Live Activity、中英文本地化资源校验通过。

### 调用身份与独立轮次结算

2026-11-27。172 项 Swift 扩展回归通过。作用域回归用相同字符串建立模型轮次和独立调用，验证容量、封口和调用身份归属。拒绝回归验证没有执行实例时保留调用身份，确认拒绝与结果未知的投影不同。全双工容量回归在调度阻塞时分别检查语义输入队列和按轮次 ID 管理的结算队列。扩展回归同时覆盖原生 Tool、Action 反馈、语义结果融合和播放控制。

最终 7 项 Swift 定向回归通过，覆盖同 ID 作用域隔离、无执行实例拒绝、全双工队列满载、ReACT、语义打断、结果重投和播报实例控制。

`./scripts/build-ios.sh` 的五个模拟器目标通过，最终源码复编译主 App 后通过 Agent／Skill、Live Activity 和中英文本地化资源校验。`./scripts/check.sh` 在既有的 State Value codec 和 Xcode 中文资源归属检查处退出。变更 Swift 严格格式、8 项 Python 工具测试、工程 plist 和 `git diff --check` 通过。设备音频与真实模型行为未在本次回归采样。

### Action 与 Tool 调用协议

2026-11-27。Swift 扩展回归 284 项通过。补跑的两项 Gateway 计时回归通过。最终源码的六项定向回归覆盖 Action 和 Tool 独立封口、拒绝迟到调用、四类回包的协议映射、可扩展的标签配对，以及全双工打断与历史并发写入后继续处理已入队输入。

`./scripts/build-ios.sh` 的五个模拟器目标通过。最终源码复编译主 App，通过 Agent／Skill 资源、Live Activity 和中英文本地化校验。`./scripts/check.sh` 仍在既有的 State Value codec 和 Xcode 中文资源归属检查处退出。变更 Swift 严格格式、8 项 Python 工程工具测试、工程 plist 和 `git diff --check` 通过。本轮验证使用自动化测试和模拟器构建，真机与真实模型验收尚未执行。

#### 提交前业务兼容复核

普通 Swift 回归的 IntegrationTests 报告 1,293 项通过，定向 Send 和 Request 的超时回归串行通过。原生集成首轮发现委派 Agent 同时订阅两类反馈时收不到独立的 Action 结果，以及声源证据写入失败后仍会发布。机械臂与蓝牙替身装配缺少内部音量 Action。修复后 29 项定向回归通过，覆盖声源写入失败、委派次轮、机械臂、蓝牙、回包关联、VAD 能量和 Gateway 超时。

最终源码的五个模拟器目标构建通过，App 的 Agent／Skill、Live Activity 和中英文本地化资源校验通过。将静态检查结果与提交前的 HEAD 对照，两处检查类别的报错一致。原生呈现套件未给出完整结果。本轮未执行物理设备或真实模型验收。

### Gateway 通信边界与 Writer Tool 直返

2026-11-27。187 项 Swift 扩展回归通过。定向回归覆盖超过 4 MiB 的完整 Tool 结果、跨会话执行拒绝、重复接线隔离、播报暂停续播、委派结果和声源诊断。Writer 使用真实 Gateway、Actions 接收端和 SQLite 测试库跑完 17 个工作区场景。两项 Gateway 超时用例串行复测通过。最后复跑的 7 项链路测试和 6 项 Wait、独立封口、打断测试均通过。

`./scripts/build-ios.sh` 的五个模拟器目标通过，App 的 Agent／Skill、Live Activity 和中英文本地化资源校验通过。`check.sh` 在既有的 State Value codec 和 Xcode 中文资源归属检查处退出，报错与修改前的基线一致。变更 Swift 格式、8 项 Python 工程工具测试、plist 和 `git diff --check` 通过。本轮未执行设备验收或传输吞吐压测。

### Assistant Tool 同请求直返

2026-11-27。57 项 Swift 扩展回归和最终 6 项定向回归通过。Assistant 的轮次回归通过实际执行返回值核对原生 Tool 与模型 toolCallID 的配对、历史持久化、并发、混合轮次、独立封口和取消。直接路径的成功和准入拒绝均验证没有 `tool.result.v1` 回投。显式异步 Tool 反馈回归及 Writer 的 17 个创作场景继续通过。

`./scripts/build-ios.sh` 的五个模拟器目标及 App 的 Agent／Skill、Live Activity 和中英文本地化资源校验通过。`check.sh` 在既有 State Value codec 和 Xcode 中文资源归属检查处退出。变更文件 Swift 严格格式、8 项 Python 工具测试、plist 与 `git diff --check` 通过。本轮未执行真机验收。

### Assistant 与 Writer 的对称执行通信

2026-11-27。真实 Actions 与 Gateway 接线回归覆盖共用终态信道、来源与会话验证、同一终态临时拒收后的重投、执行次数及轮次结算。并行 Tool 测试从同一角色会话的不同轮次复用原生调用 ID，校对每个调用收到对应且完整的长结果。Assistant 回归覆盖 Action、Tool 和混合轮次的历史关联与打断。Writer 创作场景使用实际 Gateway、Actions 工作区和 SQLite 测试库，模型响应为受控替身。

15 项 Swift 定向测试通过，含参数化的 17 个 Writer 场景和 3 个播报控制场景。`./scripts/build-ios.sh` 的五个模拟器目标通过，主 App 用最终源码复编译后通过 Agent／Skill、Live Activity 和中英文本地化资源校验。变更 Swift 文件严格格式、8 项 Python 工具测试、plist 和 `git diff --check` 通过。`./scripts/check.sh` 仍在既有的 State Value codec 和 Xcode 中文资源归属检查退出，输出与修改前基线一致。本轮未执行真实模型、原生 UI 交互或真机验收。

### 灵动岛发布请求隔离

2026-11-27。新增回归使用真实 SignalTransport，从 Actions 请求处理器提交灵动岛更新，并等待发布工作者向同一端点独立发送。修复前更新未到达且记录失败。修复后 6 项 Swift 定向测试通过，覆盖该复现、真正循环的拒绝、语音／Assistant／Writer 的发布、重试和停止，以及执行终态送达。变更文件格式和 `git diff --check` 通过。`./scripts/check.sh` 的 State Value codec 和 Xcode 中文资源归属报错与修改前基线一致。

`./scripts/build-ios.sh` 五个模拟器目标通过。模拟器与真机 App 的 Agent／Skill、Live Activity 和中英文本地化资源校验通过。签名真机构建通过，iPhone 17 Pro 已安装并读回版本 `2026112702`，设备确认启动成功。未在真机重新执行收音与灵动岛场景。

### 关键词和模型打断历史一致性

2026-11-27。对真机 SQLite 和 WAL 的只读副本执行完整性检查并比对近期记录。截图附近有已中断的回复仍保存完整生成文本，且没有 `replyTruncation`。模型 Decision 触发输入存在 `coordination.interrupt=true`，被打断回复也存在缺少截断证据的情况。设备数据未被修改。

7 项定向测试和 44 项扩展 Swift 测试通过。关键词和模型分支分别在零完成动作和跨轨道部分完成场景写入 SQLite，重开后确认截断、原文、决策来源、列表和详情投影、模型历史。全文均被保留时仍写入证据和中断状态。Swift 格式、字符串目录 JSON、`git diff --check` 通过。`check.sh` 停在基线已有的 State Value codec 与 Xcode 中文资源归属检查。

`./scripts/build-ios.sh` 的五个模拟器目标通过。模拟器与真机 App 的 Agent／Skill、Live Activity 和中英文本地化资源通过校验。iPhone 17 Pro 已安装并读回 `2026112703`，设备确认启动成功。未做真机收音与打断验收。

### 关键词打断触发输入的历史关联

2026-11-27。真机 SQLite 及 WAL 的只读副本完整性检查通过。20:26:40 的被打断回复有关键词来源和 JSON 标记，20:26:49 含「停下」的合批请求及其两个成员均缺少打断决策。20:26:33 的模型 Decision 触发记录已有打断决策。取证未修改设备数据库。

52 项 Swift 扩展测试通过。关键词先于 ASR、ASR 先于关键词和 ASR 迟于清理确认三种顺序都通过 SQLite 回读及列表和详情投影验证。合批次要成员及模型决策对照通过。变更 Swift 格式与 `git diff --check` 通过。`check.sh` 仍在基线已有的 State Value codec 和 Xcode 中文资源归属检查处退出。

五个 iOS 模拟器构建目标通过。模拟器与真机 App 的 Agent／Skill、Live Activity 和中英文本地化资源校验通过。iPhone 17 Pro 已安装并读回 `2026112704`，设备确认启动成功。未在真机复测关键词触发后的新历史条目。

### 独立 Tool 回包与执行事件

2026-11-27。定向 Swift 回归覆盖 Tool 单项直返、无轮次 Tool 不阻塞其他调用或轮次封口、拒绝结果不重复投递、执行所有者绑定，以及收听策略版本和播报控制。播报用例接入真实 Gateway 与 Actions，音频设备和模型使用替身。本轮未执行真实模型或真机验收。

普通 Swift 回归通过，IntegrationTests 报告 1,300 项。串行运行时套件通过 232 项。`./scripts/build-ios.sh` 的五个模拟器目标构建通过。主 App 使用最终源码复编译通过，Agent／Skill、Live Activity 及中英文本地化资源通过校验。

`check.sh` 在已有的 State Value codec 与 Xcode 中文资源归属检查处退出。Swift 严格格式检查、8 项 Python 工具测试、工程 plist 和 `git diff --check` 分开执行通过。

MobileHarness 0.1.0（`2026112705`）通过 iPhoneOS Debug 构建、严格签名和打包资源校验。在 iPhone 17 Pro 原位安装，设备应用清单确认构建号，App 启动成功。字幕、灵动岛和播报行为待真机验收。

### 起声确认后的连续声学让声（2026-11-28）

Swift 定向回归 7 项、18 个用例通过，覆盖未起声的高能量、起声后由 VAD 判为非语音的高能量、播放失去有声区间、能量跨 ASR 终稿、回落恢复、识别失败、路由准入和播放控制身份。替身验证了 ASR 终稿不会触发音量恢复及过期 Tool 回包不会提前续播。ASR 收尾仍沿现有采集 FIFO 排队，恢复延迟及听感留待真机测量。

`./scripts/check.sh` 在既有 State Value codec 和 Xcode 本地化资源归属检查处退出。独立执行的 8 项 Python 工程工具测试、变更 Swift 严格格式、plist 和 `git diff --check` 通过。

`./scripts/build-ios.sh` 的五个模拟器 scheme 构建通过。最终源码的 App 复编译与 Agent/Skill、Live Activity、中英本地化资源校验通过。真实模型、原生 UI 与物理设备声学验收未执行。

### ASR 声量自适应准入（2026-11-28）

语音、VAD、ASR 及播放控制 Swift 定向回归 172 项通过。替身用例覆盖高 VAD 分数的低电平拒绝、噪声底随背景更新、播放期间冻结估计、非空终稿校准、空终稿与播放重叠跳过校准、较弱尾音、连续低电平端点、换代后重新校准，以及增强后静音不触发 ASR。首轮工程回归发现的两项增强夹具与新电平契约冲突，更新夹具后定向重跑通过。另有 Decision 测试在首轮工程回归得到 `decision_failed`，四个输入隔离重跑均通过。最终普通 Swift 工程回归 1,993 项、独立串行运行时回归 232 项通过。

`./scripts/check.sh` 仍在既有 State Value codec 和 Xcode 本地化资源归属检查处退出。8 项 Python 工程工具测试、变更 Swift 严格格式、plist 和 diff 独立验证通过。`./scripts/build-ios.sh` 的五个模拟器 scheme 及 Agent/Skill、Live Activity、中英本地化资源检查通过。

实际电视对白与用户重叠时的字错率、电视单独播放的误提交、轻声和短指令召回尚未真机测量；本轮未执行真实模型和 iOS 真机验收。

### ASR 自适应版真机安装（2026-11-28）

MobileHarness 0.1.0（2026112801）通过 iPhoneOS Debug 构建、严格签名验证及 Agent/Skill、Live Activity、中英本地化资源检查。iPhone 17 Pro 从 2026112706 原位更新，安装回执序列 8328；独立设备清单确认构建号，系统启动成功。真实声学验收尚未执行。

### 播放让声恢复缓冲（2026-11-28）

6 项 Swift 定向测试、16 个用例通过。覆盖 600 ms 降音释放和 1,000 ms 暂停释放的精确样本边界、电平反弹重置等待、暂停等待期间在两种较低的档位之间波动、释放至降低或正常音量、ASR 终稿先于恢复、播放执行身份、迟到 Tool 回包和打断优先级。替身 PCM 回归验证释放命令的时序。

`./scripts/check.sh` 在既有 State Value codec 和 Xcode 本地化资源归属检查处退出。8 项 Python 工程工具测试、变更 Swift 严格格式和 diff 检查独立通过。

`./scripts/build-ios.sh` 的五个模拟器 scheme 构建和 App 打包资源校验通过。本轮未安装到 iPhone，实际听感待真机测量。

### 恢复缓冲版真机安装（2026-11-28）

MobileHarness 0.1.0（2026112802）通过 iPhoneOS Debug 构建、严格签名和三项打包资源校验。iPhone 17 Pro 从 2026112801 原位更新，安装回执序列 8344；设备应用清单确认构建号，系统启动成功。600 ms 降音恢复和 1,000 ms 暂停恢复的实际听感待测。

### 播报终态与首页麦克风频谱（2026-11-28）

- 8 项定向 Swift 测试通过。全双工后台轮次回执的四个参数场景覆盖播报终态清理；独立回执用例核对较早的执行 ID 不会清理当前目标。
- 在端到端测试中挂起语音检测，随后注入有能量的麦克风帧。UI 频谱在检测返回前已显示能量，采集结束后归零。有序业务缓冲的 64 包上限、溢出、停止和加入测试通过。
- 播放及频谱的扩展测试通过。iPhoneOS Debug 构建、严格签名及 105 项 Agent/Skill 资源校验通过，已覆盖安装到 iPhone 17 Pro。实际交互帧率与抑制听感尚未在设备上测量。
- 工程检查在既有生产模型清单校验处退出（Invalid production model catalog）。
- 五个 iOS 模拟器 scheme 均构建成功，最终 App 中英文资源校验通过。

### 播报目标音量独立设置（2026-11-28）

7 项定向 Swift 测试通过，覆盖无轮次时先降音再恢复、工具并发下维持调音顺序、语音端点绑定前设置音量、打断后的恢复以及暂停和续播。iPhoneOS Debug 构建成功，严格签名和打包的中文参数说明校验通过。仓库工程检查通过模块边界阶段后，在既有生产模型清单校验处退出。
五个模拟器 scheme 构建成功。真机安装连接首次被重置，重试后 iPhone 17 Pro 返回安装成功；未实测扬声器听感。
