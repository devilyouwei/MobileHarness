# 原生音视频故障诊断与错误保真

## 现场与证据边界

2026-11-06 用户截图：同一会话在 13:32 上报 `platform.audio.spatial nativeEvent invalidFormat` 和 `platform.vision.camera nativeEvent AVFoundationErrorDomain -11819`。本地 Apple SDK 将 -11819 定义为 `AVErrorMediaServicesWereReset`。故障版本的空间音频把运行错误和中断都替换成 invalidFormat，因此不能据截图认定 PCM 格式错误，也不能确认两个事件的因果顺序。

手机当前未连接，尚未取得系统崩溃日志或复现记录。媒体服务重置触发原因及真实设备复验属于本次未完成调查，不能以代码检查代替。

## 实施范围（先于代码）

- `PlatformKit/Audio/SpatialAudioCapture.swift`：原生运行通知保留 NSError（domain/code/userInfo）；缺失原生错误使用明确 runtimeFailed；原生中断使用 interrupted。启动未运行使用 startFailed 或 interrupted，并优先保留已收到的原生失败。停止先关闭本代通知接纳，再停止并加入原生回调，避免清理产生迟到故障。
- 同文件的通知桥独立于 FOA 硬件后端，在 macOS/iOS 均编译，以实际 NotificationCenter 通知测试错误传播；测试不得请求权限或打开设备。首个失败同时传给 readiness、PCM source 和 Platform 报告，重复事件不覆写主因。
- `PlatformKit/Audio/MicrophoneFrame.swift`：补充 runtimeFailed/startFailed 原生错误分类，不改变已有 PCM 验证。
- `Actions/Speech/Detection/AudioDetectionExecution.swift` 及本目录 README：穷举映射兼容新增错误，直接传播原生启动/运行失败，不将其映射成格式错误；不改变检测生命周期。
- `Tests/IntegrationTests/AudioCaptureReadinessTests.swift`：覆盖原生错误、无 payload、中断、启动前/后失败、重复/迟到事件及无关 session 隔离。
- 更新 Audio README 和测试 README，验证记录放 `docs/validation/`。不改变模块边界、Gateway、Writer、媒体采集策略，不推测性关闭 FOA 或自动重拍。

## 验证与后续

错误保真、启动错误分类、停止通知围栏及定向回归已实现；完整 `scripts/check.sh`（含原生运行时阶段）与四个 iOS 构建通过。媒体服务重置根因、设备日志和真机复验未完成，本调查保留在 requirements。证据见 [验证记录](../../validation/Native-Media-Failure-Diagnosis.md)。

用户补充聊天记录：13:31 ignorePhoto(media_9)→takePhoto；13:32 用户要求保存，生成 savePhoto(media_10)，消费其执行观察后又生成 closeCamera，消费 closeCamera 执行观察的下一轮 cancelled。保存和关闭所在轮均显示 completed；截图未展开 Action 执行观察，不能以轮状态替代保存/关闭原生结果。保存链路本身不停止相机；关闭在相机与视觉两个分支均无需求时才释放共享采集并加入原生停止。下一步需对照相机关闭、并行空间音频和媒体重置的细粒度时间线。

VoiceSessionCoordinator 的实际错误路径为 PCM/音频事件失败→stopVoice→requestReplyCancellation；所以末轮 cancelled 与媒体故障导致回复取消的解释相容，尚不能从分钟级截图认定因果或取消来源。当前不凭该截图修改采集策略或压制相机错误。

实施后运行定向测试、`scripts/check.sh`、`scripts/build-ios.sh`。待连接设备后读取故障时段媒体服务日志、确认触发操作，依据新证据决定是否需要媒体对象恢复修复；记录真机安装与复验结果。

Apple 恢复建议：[QA1749](https://developer.apple.com/library/archive/qa/qa1749/_index.html)。重置后的对象重建与再次激活需要结合当前所有者和用户意图设计，不能无条件重试有副作用的拍照/录像。
