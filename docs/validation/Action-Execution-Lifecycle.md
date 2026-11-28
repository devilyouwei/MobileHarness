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

## 2026-11-28 Vision 请求链隔离

- Vision/Gateway 定向回归通过。替身相机通过实际执行端点启动 Vision 会话，同一请求的直接重入仍被拒绝。原请求返回后，实际 Tool 执行链各完成一次骨架与视线调用，暂停会取消并加入等待下一帧的会话。其他用例覆盖终态排空、输入结束、取消、呈现载荷校验、角色授权和姿态观察投递。[回归用例](../../Tests/Gateway/Output/GatewayContainerTests.swift)
- 本机 Core ML 使用 `Models/YOLOPose/yolo26n-pose.mlpackage` 通过 RGB 夹具的加载、推理、卸载和重载，以及四个方向的 BGRA 夹具推理。缺少制品时显式加载失败的用例也通过。[模型验证用例](../../Tests/ModelKit/Vision/PoseTests.swift)
- `./scripts/check.sh` 在既有的 AgentContainer State Value codec 和 15 个 Xcode 中文资源归属检查处退出。改动文件的 Swift 严格格式、8 项 Python 工具测试和 `git diff --check` 单独通过。
- `./scripts/build-ios.sh` 的五个 Simulator scheme 全部通过。主 App 校验了 94 个 Agent／Skill 资源、Live Activity 和中英文本地化。真机相机、骨架和视线的现场复验未执行。

## 2026-11-28 感知角色的独立 Tool 回执

- 常规 Swift 回归通过 1,996 项，其中集成测试 1,305 项。最终源码的 38 项定向回归通过，覆盖相机启动请求返回后的姿态呈现、保存照片的实际回执、资源操作直接完成、缺失 Tool、诊断呈现失败、暂停及重新接纳请求。相机与设备端点使用测试替身。
- LiveRuntimeTests 的 232 项测试通过。原生呈现套件启动了 cameraNativeMetalDrawStopAndLayerHandoff，未报告该项结束。真机相机和 YOLO 实时叠加未验收。
- 五个 iOS 模拟器 scheme 构建通过，主 App 的 94 项 Agent／Skill 资源、Live Activity 和中英文本地化通过校验。最终应用源码使用 simulator 依赖配置复编译通过。
- 工程检查在原有 State Value codec 和 15 项 Xcode 中文资源分组处退出，输出与改动前一致。改动范围的 Swift 严格格式、8 项 Python 工具测试、工程与 plist 语法、四个角色 README 的本地链接以及差异格式检查通过。

## 2026-11-28 调用方选择 Action 或 Tool

- 12 项 Swift 定向回归通过。内置目录的 Action、Tool 路径集合一致。实际 Shell 回归用同一个函数验证同行 Action 排队、两个无资源冲突的 Tool 重叠执行，以及前一个 Action 释放后后续 Action 开始。其余用例覆盖 Tool 的轮次结算、资源冲突、取消清理、灵动岛及角色授权。
- 并发回归首次运行因夹具共用单等待者门闩超时。将两个执行分别绑定到独立门闩后重跑，12 项全部通过。Swift 严格格式、8 项 Python 工具测试、plist 和差异格式检查通过。全量 `./scripts/check.sh` 仍在已有的 State Value codec 和 Xcode 中文资源分组检查处退出。
- 五个 iOS 模拟器目标构建通过。主 App 的 94 项 Agent／Skill 资源、灵动岛扩展和中英文本地化通过校验。未执行真实模型、原生 UI 交互或真机验收。

## 2026-11-28 合并相机与视觉感知角色

- 42 项定向用例和 232 项 LiveRuntime 用例通过。测试覆盖相机事务回执、启动请求与后续姿态呈现的隔离，以及没有外部姿态订阅者时的本地跟踪接纳。相机与设备使用测试替身。
- 五个 iOS 模拟器 scheme 构建通过，打包校验通过 92 项 Agent／Skill 资源、灵动岛扩展和中英文本地化。未执行真机 YOLO 加载与相机叠加验收。
- 常规回归的 1,307 项集成测试中有两项失败。授权集合断言还发现 `UI.Island.setPresentation` 缺少授权。`spokenStopUsesTheDecisionResult` 的四个输入在单独复测时全部通过。工程检查仍报告 AgentContainer 的 State Value codec 和 14 个中文资源的工程分组问题。差异格式检查通过。

## 2026-11-28 Memory 独立 Tool 事务

- 166 项历史、记忆、标题及启动装配相关 Swift 回归通过。覆盖 UI 请求以及 Memory 输出会话收到删除回执后再刷新、拒绝从公共收件箱注入 ToolResult、取消和失败、查询权限、标题推理与记录。标题推理使用测试替身。
- 五个 iOS 模拟器 scheme 构建通过。主 App 的 92 项 Agent／Skill 资源、灵动岛和中英文本地化通过打包校验。未执行真实模型或真机验收。
- 工程检查在 AgentContainer 的 State Value codec、三份模块 AGENTS.md 的 Xcode 引用和十四项中文资源分组处退出。Memory 源码严格格式、角色 README 链接、Xcode 工程语法和差异格式检查通过。

Memory 输入职责调整后，159 项 Memory／历史相关 Swift 测试通过。角色源码严格格式、README 链接、工程语法、差异格式和主 App 模拟器构建检查通过。工程静态检查仍报告 AgentContainer 的 State Value codec 及 14 个中文资源分组问题。

## Assistant 模型等待动画 Tool

67 项相关测试通过，覆盖 Assistant 的内部授权、回复字幕和播放、等待请求的六类终止情况，以及独立等待 Tool 早于调度的回复开始 Action 到达时的呈现顺序。主 App 模拟器构建通过。工程静态检查仍报告 14 项既有中文资源工程分组问题。未做真机动画观察。

## 2026-11-28 模型 Skill 与固定 Tool 的装配

117 项定向 Swift 测试通过，包括四个无 Skill 角色的配置、误配拒绝、固定工具授权和 Assistant 的模型 Skill。逐个检查随包 Skill 绑定，Assistant 的等待动画、音量与灵动岛内部工具均未注册。五个 iOS 模拟器 scheme 构建通过。未进行真机或真实模型验收。

全量 Swift 集成测试中，既有的 `UI.Island.setPresentation` 声明缺少授权仍可复现；语音识别失败后恢复监听的测试在全量运行中失败，单独复跑的两个用例均通过。独立运行时阶段 232 项通过。工程检查仍在 14 个中文资源的 Xcode 分组检查处退出。

## 六个角色的目录职责回归

六个角色共 127 个 Swift 文件，逐一核对了唯一 Xcode 引用、父分组和物理目录。六个角色的 Swift 格式、工程语法、源码文档链接和差异格式检查通过。五个 iOS 模拟器 scheme 构建通过。

按角色、Skill 和工作流筛选的 Swift 回归仍报告一项既有失败：UI.Island.setPresentation 缺少调用方授权。工程检查在十四个中文资源的 Xcode 分组处退出；单独诊断后续检查还遇到生产模型目录与检查器预期不一致。未执行真机或真实模型验收。
