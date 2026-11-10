# 原生音视频故障诊断验证

日期：2026-11-06。对应 [调查与实施范围](../requirements/technical/Native-Media-Failure-Diagnosis.md)。

## 现场证据

用户截图同一会话 `4E76A53A-813E-475F-80D6-818E8914220E`、13:32 同时显示空间音频 `nativeEvent invalidFormat` 与相机 `AVFoundationErrorDomain -11819`。

第二张聊天记录截图补充：13:31 忽略 media_9 后重拍；13:32 用户要求保存，模型生成 savePhoto(media_10)，下一轮消费保存执行观察并生成 closeCamera，再下一轮消费关闭执行观察时 cancelled。前两轮显示 completed，执行观察正文未展开。分钟级时间与轮状态无法证明具体 Action 成败、媒体重置相对关闭的先后或最后取消的发起源。

关闭调用沿 Camera.Capture.close→CameraCoordinator.setEnabled(false)→closeWindow→setDemand(false)；若 Face 视觉分支仍需求采集，只关闭照片分支，否则等资源释放/原生停止。音频故障则可沿 VoiceSessionCoordinator.stopVoice→requestReplyCancellation 取消 Assistant 回复。两条代码路径与现场相容，因果关系待设备日志确认。本次补充调查未继续修改代码，仅更新证据与待验证顺序。

本地 Apple SDK `AVError.h` 明确 `AVErrorMediaServicesWereReset = -11819`。空间音频旧通知桥会丢弃 NSError 并统一报 invalidFormat，无法从旧截图判断其实际错误或与相机的事件顺序。相机预览设置 `automaticallyConfiguresApplicationAudioSession = false`；照片保存只提交 App 相册并执行退场动画与短音效，未发现该路径主动重配音频会话或启停聆听。

## 自动验证

- 通知测试使用真实 NotificationCenter、未运行的 AVCaptureSession 和实际首帧/PCM 源；注入原生错误，覆盖首帧前后、NSError 信息保留、无 payload、中断、重复事件、无关 session 和停止后通知。它不是实际媒体服务崩溃复现，不请求设备权限或打开硬件。
- 完整 `scripts/check.sh` 通过（exit 0）：边界/格式检查、Python 6 项、全部默认 Swift 测试目标、1054 项集成测试及独立原生运行时阶段 227 项（206.467 秒），最后 plist 检查通过。可选真实模型/真机测试保持原有条件跳过，不作为本轮验收。日志 `/tmp/mh-media-check.log`。新增原生通知测试 3 个函数、5 个案例全部通过。
- `scripts/build-ios.sh` 通过（exit 0）：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个 scheme，含应用 Agent/Island 资源检查。日志 `/tmp/mh-media-ios-build.log`；空间采集 arm64/x86_64 目标对象均在最终源码修改后编译。
- 定向测试早期暴露新增 AudioIOError 分支遗漏，已补检测端原样传播；NSError 跨 Swift throwing 桥接不承诺对象 identity，断言改为错误值相等并保留 userInfo 检查。

## 真机限制与待验证

`devicectl` 将 iPhone 17 Pro `00008150-000579D114C2401C` 标记 unavailable；读取媒体服务崩溃日志失败（CoreDeviceError 4016，缺少设备可连接状态）。本轮尚未安装修复、读取系统日志或完成真机复现/复验。

待设备连接后核对保存前后的原生故障和聊天时间线，再判断根因及恢复路径。当前修复只证明错误保真和代际终止行为，不证明媒体服务重置已消除。

## 模型失败与聆听恢复链路审计

用户进一步提出 Language 模型超时、空回复的可能性，要求检查基础模块失败是否停止聆听。本次仅核对代码、运行现有回归并记录结果，未修改运行逻辑。空回复本身不能证明超时，也不能解释原生 AVCaptureSession 的 -11819；尚缺该请求具体 failureDiagnostic。

- 基础模块故障广播经 ContainerFailureChannel 到 ApplicationControl 展示与 Assistant.observeFailure 保存诊断，不调用停止聆听或自动取消模型。请求自身必须传播失败，才会进入回复终止路径。
- AgentChatDriver 将请求打开/流错误和取消传播给 AgentChatWorker；collect 无可执行回复时明确失败。executeRound 遇模型错误仍封闭并等待已接纳 Action/Tool 的 roundReceipt，随后抛错；并非跳过原生完成而立即解锁。
- generate 将请求/输入落为 failed 或 cancelled；agent.error/agent.cancelled 终止回复占用并发送 ReplyActivity。宿主取消另由 finishHostCancellation 和最终快照完成占用收尾。错误终止不记为成功 completed。
- SpeechPerception 按所有来源的占用及 pendingFinal 汇总 paused，用户 enabled 许可单独保留。空闲后发 Speech.Listening.update(enabled=true, paused=false)，VoiceSessionCoordinator 在代际有效、无播放屏障、无录像占用时 resumeListening，正常半双工复用仍运行的麦克风。错误/取消显示路径只取消对应语音缓存，不直接 stopVoice。
- 实际音频中断、路由变化、PCM 结束/报错，以及恢复采集失败仍走 stopVoice，撤销本代聆听并取消回复；现有实现不会自动重建故障采集。这与单纯 Language 模型失败不同。ASR 单轮推理失败有独立恢复并接纳下一句话的路径。
- 共享 Chat 层没有统一无输出/整轮 watchdog；云端适配器配置请求超时（默认 60 秒），本地/未终止流不因长时间无结果自动落失败。只有真实终止或取消才能触发上述恢复；原生清理、其他角色占用或未完成播放也可延后恢复。

定向执行 8 个测试函数、22 个参数案例通过（3 次 swift test 均 exit 0）：

- `/tmp/mh-reply-failure-listening-audit.log`：回复等待六种结束、终态恢复保留许可、汇总占用、ASR 失败后下一句话、显式用户关闭。
- `/tmp/mh-reply-cancellation-listening-audit.log`：取消期间新发/在途空闲事实穿过 Gateway、等待实际播放清理、聆听可再次启用。
- `/tmp/mh-model-terminal-audit.log`：八种模型请求失败/取消保存真实终态且不重试，以及故障广播只做诊断。

这些是夹具/软件路径回归，未新增真实云端超时实验或真机录音验证；本次没有代码变更，不重复全量构建。

## 2026-11-10 14:51 真机关闭相机故障

用户在已安装 2026111005 的 iPhone 17 Pro 上先拍照，再要求新建网页窗口访问百度。只读获取系统 `cameracaptured-2026-11-10-145104.ips` 以及 App records.sqlite/WAL 副本；本地 SQLite quick_check 返回 ok。设备复制曾因 CoreDevice 连接中断失败，顺序重试后取得完整副本。未操作手机数据库、重放用户动作或修改生产代码。

### 已确认的时间线（Asia/Shanghai）

| 时间 | 证据 |
| --- | --- |
| 14:50:22.055 | Assistant 消息 199 已消费 takePhoto 成功观察：preview_1，3024×4032 JPEG；拍照动作成功。 |
| 14:50:46.990 | 消息 200 接收新建网页窗口、访问百度搜索的请求。 |
| 14:50:54.059 | 该模型请求 HTTP 200 完成，输出只有 closeCamera。 |
| 14:51:03.333 | 消息 201 消费 Camera.Capture.close succeeded、enabled=false 的观察，并启动下一轮模型请求。 |
| 14:51:04.144 | 系统 cameracaptured 崩溃，EXC_BREAKPOINT / SIGTRAP。 |
| 14:51:04.395 左右 | 下一轮记录 CancellationError，消息 201 于 14:51:04.396 标为 cancelled；没有生成网页访问 Action。 |

系统版本 iPhone OS 27.0.1（24A446）。崩溃线程为 com.apple.coremedia.capturesession.workerQueue，关键栈：

```
BWGraph _timedOutWaitingForOperationToCompleteWithDescription:briefReason:offendingNodes:
BWGraph _attributeGraphTimeoutWithStopping:
BWGraph stop:
captureSession_stopGraph
captureSession_stopRunningInternal
captureSession_updateSessionRunningCondition
```

这确认系统采集图在停止过程中超时并终止服务；截图中音频空间采集和相机同报 AVFoundationErrorDomain -11819 与该服务故障时间吻合。原生 -11819 在 SDK 中为 AVErrorMediaServicesWereReset。所读请求链没有 Web 浏览 Action，不能归因于百度网页加载。close 当时成功并不证明随后系统媒体服务仍健康；下一轮取消与现有音频故障→stopVoice→取消回复的链路一致，但持久记录未提供取消发起者的完整因果标识。

报告没有指出具体阻塞节点，也未给出引发停止的客户端栈，因此尚不能证明 FOA 与相机并存、音频会话重配或某一个 App stop 调用就是底层超时根因。现有空间音频和相机分别使用 AVCaptureSession，空间采集允许系统自动配置应用音频会话；此组合应进入对照实验，不能仅凭本次日志直接关掉 FOA。

### 修复方向与验收边界

1. 先修正文窗意图教学和回归：新建网页窗口不隐含关闭相机、结束摄影或丢弃未保存照片；明确关闭/替换请求才走相应处置。此次只有新网页请求却先 closeCamera，应单独评估模型决策问题。
2. PlatformKit 将媒体服务 lost/reset 作为可识别生命周期事件，加入并退休失效代的采集/播放工作，保留原始错误；同代 stop 不能用 stopped 覆盖期间已发生的 failed。音频引擎、播放器、转换器及失效相机图的重建由原拥有者负责，上层继续使用稳定接口。
3. Actions 负责用户许可和恢复入口：故障关闭受影响会话；用户再次启用时完成必要的原生重建、配置和首帧验证，不重拍、不重复保存、不重放旧模型 Action。遵循 [Apple 重置恢复建议](https://developer.apple.com/library/archive/qa/qa1749/_index.html) 的用户发起再次激活约束。
4. 真机对照相机单独启停、相机+mono、相机+FOA，以及拍照后显式关闭；记录 start/stop 起止、代际、音频路由/配置和 native error。与无相机的网页打开对照，定位何种组合触发系统 stop 超时后再决定采集协调调整。用系统 Reset Media Services 验证恢复；故障注入测试不替代真实触发复现。

本次仅完成分析和方案整理，未改代码、构建或安装。原始系统崩溃报告暂存 `/tmp/mh-media-1451-camera.ips`；手机数据库临时副本在分析后删除，不入库。以上结论来自现场记录及源码核对，不宣称问题已经修复。

## 2026-11-10 修复实施与自动化验证

本次在既有 assistant-owned-speech 分支继续修改，未提交、未覆盖真机安装，保留前序 Speech 内聚及 Agent category 修改。

实施范围：
- 采集故障不再调用取消回复或撤销聆听意图的路径；Actions 持有一次、有界、可取消并加入的音频恢复。系统中断/路由变化不自动重启；恢复耗尽显示真实不可用，明确开启可再次尝试。
- PlatformKit 完整停止后重建录放音图，reset 通知终止失效 PCM/播放等待并保留原生错误；并不自动重放相机或其他业务操作。
- 显式模型调用失败仍走现有结果观察/ReACT；同轮内部语音/字幕失败不遮蔽这些观察。无业务观察的内部失败保持原有不自动续推契约。
- 常驻 Assistant 及摄影/应用控制/Web 教学明确多窗口独立管理；去掉摄影保存、Task 完成/替换时隐式关闭相机的规则。

验证过程：
- 初次针对性运行：恢复成功/失败、停止加入、超时、中断五项测试通过；提示词测试发现原有大小写断言不匹配，修正教学句首后继续验证。
- 新的 ReACT 回归首次编译发现测试计数器被 Sendable 闭包捕获，改为 actor 持有；未改变生产并发约束。
- 首轮 iOS 编译通过，随后资源校验发现构建期间更新了 Photography 教学而拒绝旧包；以稳定资源重新构建，四 scheme 通过（/tmp/mh-media-recovery-ios-final.log）。后续取消/恢复围栏细化后再验证最终源码。
- 首次完整 check 的关键新集成用例 actionFailureContinuesReActDespiteSpeechFailureAndAcceptsNextInput 通过：Action 原生风格错误 + 同轮语音失败后仍续推，且下一输入完成。Integration 1116 项中既有 applicationControlPresentationFailureDoesNotFeedBackOrStopBusiness 与 slowTrackingDispatchExecutesOnlyTheNewestPendingTarget 失败，保留 /tmp/mh-media-recovery-check.log，不将首次全检描述为通过。

最终源码的针对性回归 /tmp/mh-media-recovery-regression.log 通过：7 项恢复生命周期测试，以及新 ReACT 回归和上述两个已有失败用例单独复跑，共 10 项。最终 ./scripts/build-ios.sh 退出 0，四 scheme 均 BUILD SUCCEEDED，资源校验通过（/tmp/mh-media-recovery-ios-verified.log）。第二次完整 check 仍退出 1（/tmp/mh-media-recovery-check-verified.log）：既有 slowTrackingDispatchExecutesOnlyTheNewestPendingTarget 在整批中失败，异常展示用例通过；新 native-start 超时取消测试的 50ms 人工期限在批量负载下失败。把该测试期限改为 2 秒，保留另一 50ms 超时用例；生产上限仍为 10 秒。最终针对性回归共 37 项通过（/tmp/mh-media-recovery-regression-final.log），包括七项恢复与提示词/ReACT；两次完整运行的 LiveRuntime 229 项均通过，Python 六项、格式/边界/plist 检查通过。完整 check 不标为全通过，既有跟踪整批时序问题仍保留。测试替身与构建不能证明系统 cameracaptured 的 BWGraph 超时消失；相机单独/mono/FOA 对照、真实重置、系统中断、恢复后首帧与语音均需真机复测。没有重拍/保存重放，也没有修改用户数据库或媒体。

最后补验：最终源码的完整 AppWorkflowTests 184 项通过，包含调整后 native-start 超时取消测试（/tmp/mh-media-recovery-workflows-final.log，退出 0）。最终 git diff --check 与本轮文档相对路径检查通过。剩余自动化限制是既有跟踪用例整批时序波动；未修改该跟踪实现或测试来掩盖失败。

## 2026-11-10 修复版真机安装

用户随后明确要求安装真机。当前工作树签名构建为 Mobile Harness 0.1.0（2026111006），使用已有本地签名配置与 build/DeviceDerivedData，不修改仓库签名或版本配置。真机构建退出 0；33 项 Agent/Skill 资源、Live Activity 扩展一致性及 codesign --verify --deep --strict 均通过。

原位更新到 iPhone 17 Pro（00008150-000579D114C2401C），安装流水 6528；独立应用清单确认版本由 2026111005 更新到 2026111006，devicectl 启动请求成功。未卸载、清空或直接修改应用数据。本次完成安装与启动确认，不等同相机/网页/真实音频故障恢复验收。

证据：/tmp/mh-media-recovery-device-build.log、/tmp/mh-media-recovery-device-before.json、/tmp/mh-media-recovery-device-install.json、/tmp/mh-media-recovery-device-launch.json、/tmp/mh-media-recovery-device-after.json。

## 2026-11-10 提示词职责收敛

用户指出新增教学应当解耦且不包含特定场景。已删除 Photography 内的拍照后访问百度场景和 Web 调用教学；删除 ApplicationControl/WebBrowsing 对 Camera 的举例及重复通用规则。独立窗口与 Task/Skill 生命周期、显式关闭意图的原则由常驻 BasicSkill 的 Lifetime and completion 独占；Assistant Instructions 恢复身份/交互边界，失败教学复用 BasicSkill 既有条款；领域 Skill 保留自身操作、媒体处置和真实回执语义。四项 Skill revision 已递增。

现有提示词组合测试验证通用规则由 BasicSkill 提供且只组装一次，领域教学不复制该规则，Photography 不包含 Web.browse 或 Baidu。模型实际遵从情况仍需真实交互验收；本轮没有重新安装，手机上的 2026111006 仍为前一版提示词。最终 ./scripts/check.sh 退出 0：1,116 项集成、184 项工作流、229 项独立原生运行时测试及格式/边界/Python/plist 检查通过（/tmp/mh-prompt-decoupling-check.log）。./scripts/build-ios.sh 四 scheme 与资源校验均通过（/tmp/mh-prompt-decoupling-ios.log）；git diff --check 通过。既有跟踪与异常展示用例本次整批通过，前轮失败证据保留，不据此声称时序波动已被修复。

## 2026-11-10 通用教学版真机安装

用户再次请求安装。使用既有本地签名构建 Mobile Harness 0.1.0（2026111007），真机构建、33 项 Agent/Skill 资源、Live Activity 扩展版本一致性与严格深层签名校验通过。原位安装至 iPhone 17 Pro，安装流水 6536；独立设备应用清单确认由 2026111006 更新至 2026111007，未卸载或清空应用数据。

安装后的启动请求未成功确认：首次 devicectl launch 返回远程连接失效（CoreDeviceError 3 / Mercury 1001），重试返回设备连接状态不足（4016），随后设备清单为 unavailable。不能声称本轮应用启动成功或完成真实模型交互验收；安装与版本确认已先于断连成功完成。

证据：/tmp/mh-prompt-decoupling-device-build.log、/tmp/mh-prompt-decoupling-device-before.json、/tmp/mh-prompt-decoupling-device-install.json、/tmp/mh-prompt-decoupling-device-after.json、/tmp/mh-prompt-decoupling-device-launch.json、/tmp/mh-prompt-decoupling-device-launch-retry.json。
