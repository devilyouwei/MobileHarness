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
