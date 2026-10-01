# ADR 0017 · 新设计第一阶段：入口到 Gateway

> Source layout: [ADR 0063](0063-module-directory-consolidation.md) supersedes standalone runtime targets and former top-level Core/presentation locations; the behavioral decisions below remain historical records.

日期：2026-09-24。状态：已采用，分阶段迁移。

## 决策

以 MobileHarness/README.md 为后续设计目标，本轮仅迁移 App、Experience、Gateway。旧 docs/Tech_Design.md 与 Technical_Design.docx 保留，后续模块不因目录迁移而假定已符合新契约。

App 保留 Bootstrap/LifecycleCoordinator 辅助拆分，将 Kokoro provider 创建收口到 AppContainer。Experience 提取 Components 的圆环和字幕，保留 Diagnostics 验证入口。Gateway 从 Request/Response 迁至 Input/Output，入口类型对应改名；EventRouter 改为 SignalRouter 协议。Output 拆成 Validation、Routing、Dispatch，实际调用链使用这些实现。根包仍映射唯一源码，Xcode 更新导航与两个 App target 的组件编译引用。

## 保持的行为与过渡边界

模型选择、预热、权限、VAD/ASR 分段、partial/final、逐句 say/print、工具回流、模块 FIFO、容量与溢出策略、取消与完成屏障不变。OutputGateway 的 requests 初始化标签暂保留，参数类型变为 InputGateway；仓库所有调用同步迁移，不新增旧类型兼容别名。

AgentCore 的 AgentInput/FunctionToken/ToolCall/control 暂不修改。SignalRouter 暂接收 AgentInput；ActionDispatcher 暂解析 AgentDescriptor 绑定，再交给 ActionRuntime。它们是明确的兼容边界，不是完成后的新设计。未实现 Signal、ContextBuilder、GhostShell、Channel、ActionResult，不创建相应空文件。后续 AgentCore/Agents 迁移后才能移除输出侧别名解析并引入 Channel 调度。

## 维护与验收

本轮所有实际目录都有 README，以 ✅/❌ 记录用途、设计目标、进度和边界；修改目录时同步更新。保持根 Tests 和独立模型包测试布局。本轮运行 scripts/check.sh、完整 Xcode 下 scripts/build-ios.sh，并补充真机无签名编译；自动检查不能代替真机麦克风、音质与连续语音验收。

## 本轮验证结果

- ✅ `scripts/check.sh`：格式、Swift 测试（含 35 项集成测试）和配置校验通过；现有 5 项真实模型/系统音频测试按默认开关跳过。
- ✅ `scripts/build-ios.sh`：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAudio8 五个模拟器 scheme 构建通过。
- ✅ 本阶段所有目录 README 覆盖、源码引用唯一性与两个 App target 的组件编译引用核对通过。
- ❌ 本轮未安装真机、未进行麦克风/连续语音与音质人工回归；编译和替身测试不等于真实设备验收。

检查在 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 下完成。初次沙箱内检查因系统缓存不可写失败，获得执行权限后通过。未修改全局 Xcode 选择或签名设置。既有 AgentCore/Agents/ToolRuntime/PlatformKit 的 README 未排除警告仍存在，不涉及本轮新增 Gateway 文档。
