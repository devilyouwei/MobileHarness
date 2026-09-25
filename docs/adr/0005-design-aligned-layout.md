# ADR 0005 按技术方案整理源码目录

状态：已实施。日期：2026-09-23。

用户指出原 App/ 与 Packages/HarnessKit/Sources/ 物理布局偏离 Tech_Design.md 第 16 节。源码统一迁至 MobileHarness/ 下的 App、Experience、Gateway、AgentCore、Agents、ToolRuntime、ModelKit、PlatformKit 和 Resources，测试迁至根 Tests/。

根 Package.swift 对同一套源码声明现有可独立测试的 target。保留编译期边界和原公开模块名，避免为目录迁移撤销 ModelKit 的隔离约束。ModelKitRuntime 和 AppleSpeech adapter 分别位于 ModelKit/Backends/Bindings 与 Runtime/AppleSpeech，属于独立 target；ModelKit target 排除整个 Runtime 子树。

AppContainer 负责具体依赖构造，AgentBootstrap 负责注册，AppLifecycleCoordinator 保留当前运行及语音协调，ConversationViewModel 负责页面状态门面。Agent 契约、Function/Tool 类型、生命周期状态、Gateway 路由和校验从聚合文件分离。未新增模型、业务 Agent 或空壳服务。

此前用户确认的 ModelKit 作为零业务依赖 SDK 的约束继续有效，优先于技术方案 2.2 的示意依赖箭头。此次保留既有数据流和公开接口；未完成的方案语义继续由 Roadmap 跟踪，不因目录对齐标为完成。

验收：根脚本完成格式检查、模块测试与 Xcode 模拟器构建；源码路径、Xcode 引用和活动文档链接有效。语音 code=300 的多轮实测不属于目录迁移已验证结果。
