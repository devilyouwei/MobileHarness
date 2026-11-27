# Action 执行反馈与打断续说验证

2026-11-26。关联[技术要求](../requirements/technical/Action-Execution-Lifecycle.md)。

## 回归范围

- 调度器和 Gateway 验证实际 Action 的起止配对、独立模型轮次起止、真实结果重投及拒绝。
- 会话打断验证旧执行取消、清理无法确认时保留输入与停止自动回复、暂停后接收旧轮次回执。
- 语音测试用替身模型验证起声候选、在途 ASR、空转写、采集切换和清理与 VAD 的不同先后顺序。合成 PCM 流经过实际语音分段逻辑，用固定 VAD 输出验证第 63 个 512 样本窗口及旧代隔离。

## 检查与验收

- 使用完整 Xcode 的 SwiftPM 回归通过 152 项，包含已封口和未封口轮次的宿主取消。运行范围包括 GenerationRound、InputDecision、ActionLifecycle、SpeechEnhancementWorkflow、Communication、AgentArchitecture 和 Assistant Action 执行。用例使用合成 PCM、替身模型和替身设备。
- `./scripts/build-ios.sh` 的五个 iOS Simulator scheme 构建通过。最终版本的 MobileHarnessSimulator 单独重编译通过，包内 92 项 Agent 和 Skill 资源、Live Activity 及英文和简体中文资源均通过脚本校验。
- 本次涉及的核心 Swift 文件通过严格格式检查。资源 JSON 可解析，`git diff --check` 通过。
- `./scripts/check.sh` 在工作区既有静态检查问题处退出。报告包括 `AgentContainer.swift` 的 State Value codec 和 15 个简体中文资源的 Xcode 目录归属。
- 真机交互、原生 Toast 展示、真实模型识别均需独立验收。

## 64 窗口复验

调整续说观察为 64 个实际 512 样本 VAD 窗口。3 项 Swift 定向回归通过，覆盖 10 个场景。合成 PCM 在第 63 个窗口仍未发出放行回执，第 64 个发出且只发一次。同一语句连读用例先计满窗口，再送入完整终稿，确认 Assistant 在终稿到达前继续等待。五个 iOS Simulator 构建及主 App 资源校验通过。全仓检查仍遇到上节记录的静态检查问题。

## 2026-11-26 真机安装

使用现有签名配置构建 Mobile Harness Debug `0.1.0 (2026112603)`。深层严格签名、92 项 Agent 和 Skill 资源、Live Activity 与中英文资源均通过校验。已覆盖安装到 Youwei’s iPhone 17 Pro，设备清单返回构建号 `2026112603`，系统确认启动成功。语音链路和真实模型效果留待真机交互验收。

## Agent 内部 Control 日志

2026-11-27。23 项定向 Swift 回归通过，覆盖 Control 成功和失败、凭据字段隐藏、调用及输入归属、来源和状态筛选，以及新调度快照与 Control 保留上限。普通回归与模拟器编译同时运行时，两项语音 Decision 用例失败，纳入串行复跑后通过。Swift 严格格式、8 项 Python 工具测试、plist 与 `git diff --check` 通过。`./scripts/check.sh` 在已有的 State Value codec 和 Xcode 中文资源归属检查处退出。

五个 iOS 模拟器目标构建通过。主 App 使用最终源码复编译通过，Agent／Skill、Live Activity 和中英文本地化资源通过校验。真机标签视觉验收尚未执行。

Mobile Harness `0.1.0 (2026112706)` 通过 iPhoneOS Debug 构建、严格签名及打包资源校验。iPhone 17 Pro 原位更新成功，设备应用清单读回构建号 `2026112706`，系统确认 App 启动。Control 记录和标签的实际显示待真机交互验收。
