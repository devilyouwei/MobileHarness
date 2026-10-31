# Diagnostics — 诊断展示与请求控制

## 职责与上下游

UIDiagnosticsContainer 唯一创建 SpeechDiagnosticState 和 AudioDetectionState，暴露各自 Presenting 接口。上游注入合成／播放／录音／聊天检查执行者；UI 接收展示值并提交本地类型化请求，不拥有模型、麦克风、播放器或方向估计算法。

诊断用于验证真实能力，保留实际失败；结果与生产、模型稳定性及物理设备验收分开记录。

## 文件与内部关系

| 文件 | 职责 |
| --- | --- |
| UIDiagnosticsContainer.swift | 诊断子容器和共享根接纳 |
| SpeechDiagnosticState.swift | 合成诊断展示、控制／呈现协议 |
| MossValidationView.swift | 注入的合成试听表单及报告 |
| ChatValidationView.swift | DEBUG 下的页面级聊天检查 |
| AudioDetectionWorkflow.swift | 音频检测状态／接口、类型化输入及设置内嵌 Section |

✅ 音频检测状态、显示协议、类型化输入及 Section 统一归 AudioDetectionWorkflow.swift；Container 请求由负责角色直接消费。

## 合成与聊天诊断

SpeechDiagnosticControlling 提供开始／停止，执行者负责独占接纳、模型／播放清理及报告格式化；页面消失请求停止，不把请求发出当作硬件停机。

ChatValidationView 的检查任务为页面作用域且仅 DEBUG 可用，离开取消；不执行设备 Action 或采集音频。MOSS 表单允许合成试听，保留实际错误及可复制报告，不使用模拟结果。

## 音频检测状态与请求

UIDiagnosticsContainer 暴露单消费者 detectionRequests：开始使用普通入口，停止使用独立控制入口。ApplicationControl 直接订阅，页面没有设备执行任务或业务计时器。离场／失活提交停止；回执与原生清理完成分离。

AudioDetectionSnapshot 区分输入、空间支持、实际布局、回退、PCM 新鲜度及方向证据。Actions 提交展示状态并驱动显示新鲜度刷新；UI 只按显示期限清理过期方向，不拥有设备、角色、仓库或推理。

## 生命周期与待完成项

✅ 展示更新经过共享 UI 根接纳；停止后的迟到结果不能修改状态。后台保留诊断事实，设备是否继续或停止由外部执行拥有者决定。UI stop 不是录音或播放停止回执。

❌ 实际模型、声音质量、音频路由和设备连续性验收仍独立进行。

[UI 根](../README.md) · [设置嵌入入口](../Settings/README.md)

## 直连链路当前契约

✅ 检测页面提交类型化请求，业务计时及执行交给 Agent／Actions，显示刷新仍由 UI 持有。

✅ DEBUG ChatValidationView 增加串行再次验证入口，实际请求完成后才可重试，用于同进程冷／热调用测量；任务仍有限且页面退出取消，结果／错误来自原能力，不授予业务或设备操作权限。

## Passive state observation

The owning stateSnapshot entry point reads current local business/capability values and runtime admission/work facts in the owner's isolation domain. It performs no action, acquisition or device activation. The module root composes the explicitly selected fields; unknown diagnostic coverage is not healthy evidence. Domain-specific completion and failure contracts above remain authoritative.

Diagnostic test running/stopping, audio workflow phase, support/capture/fallback and sample rate are Runtime. The audio child Business contains actual input route, signal/level, direction/angles and optional permission observations. Stable raw-value enums, units and value sets describe these fields. Reading does not refresh, alter expiry or activate capture. Business sampleAgeSeconds/signalFresh/directionFresh distinguish historical display values from current receipt/angle evidence; missing receipt/deadline remains unknown.

UIDiagnosticsContainer returns only its local admission and speech/audio indices. SpeechDiagnosticState and AudioDetectionState own independent stateSnapshot() async throws readers. Sampling the root never reads child workflow, configuration or sensory values.
