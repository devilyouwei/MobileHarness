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
