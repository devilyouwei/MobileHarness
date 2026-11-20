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
