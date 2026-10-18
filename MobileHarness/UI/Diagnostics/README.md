# Diagnostics — 诊断展示与请求控制

## 职责与上下游

UIDiagnosticsContainer 唯一创建 SpeechDiagnosticState 和 AudioDetectionState，暴露各自 Presenting 接口。上游注入合成／播放／录音／聊天检查执行者；UI 接收展示值并转发控制，不拥有模型、麦克风、播放器或方向估计算法。

诊断用于验证真实能力，保留实际失败；结果与生产、模型稳定性及物理设备验收分开记录。

## 文件与内部关系

| 文件 | 职责 |
| --- | --- |
| UIDiagnosticsContainer.swift | 诊断子容器和共享根接纳 |
| SpeechDiagnosticState.swift | 合成诊断展示、控制／呈现协议 |
| MossValidationView.swift | 注入的合成试听表单及报告 |
| ChatValidationView.swift | DEBUG 下的页面级聊天检查 |
| AudioDetectionWorkflow.swift | 音频检测状态／接口、限时展示工作流及设置内嵌 Section |

✅ 音频检测的状态、接口、展示工作流和设置内嵌 Section 统一归 AudioDetectionWorkflow.swift；页面通过同一公开组件嵌入，执行端点由上游注入。

## 合成与聊天诊断

SpeechDiagnosticControlling 提供开始／停止，执行者负责独占接纳、模型／播放清理及报告格式化；页面消失请求停止，不把请求发出当作硬件停机。

ChatValidationView 的检查任务为页面作用域且仅 DEBUG 可用，离开取消；不执行设备 Action 或采集音频。MOSS 表单允许合成试听，保留实际错误及可复制报告，不使用模拟结果。

## 音频检测状态与工作流

AudioDetectionSnapshot 区分原生输入、空间支持、实际布局、回退、PCM 新鲜度及方向证据。超过一秒没有新帧显示 noAudio，方向按新鲜度清理；UI 不推导原生算法结果。

AudioDetectionWorkflow 只调用注入的整次 AudioDetectionRunning 端点，一个 operation 加一个100ms新鲜度／期限 monitor，无等待队列。捕获就绪后计算检测期限；stop 同步关闭 generation、取消两个任务，stopAndWait 加入实际端点及监控清理。取消不伪造成功，真实错误显式显示。

## 生命周期与待完成项

✅ 展示更新经过共享 UI 根接纳；停止后的迟到结果不能修改状态。后台保留诊断事实，设备是否继续或停止由外部执行拥有者决定。UI stop 不是录音或播放停止回执。

❌ 实际模型、声音质量、音频路由和设备连续性验收仍独立进行。

[UI 根](../README.md) · [设置嵌入入口](../Settings/README.md)
