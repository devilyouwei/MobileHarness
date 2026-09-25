# ADR 0020：按正式 README 对齐实现目录与命名

状态：采用。日期：2026-09-24。

设计权威入口变为 MobileHarness/README.md，旧 TECH_DESIGN 文件名不再使用。保持设计原文及原始 Word 不变；差异表位于 docs/Repository-Structure.md。

将 Actions/Display 改为 UI，Say.swift / SpeechActions.say 改为 Speak.swift / SpeechActions.speak；实际路径同步为 UI.* 和 Speech.speak。模型 alias say 与默认 Speech / Display Channel 保留，避免改变现有生成和播放行为。

Actions/Runtime 移到独立 ActionRuntime target，ActionCatalog 改为 ActionRegistry，提取 ActionExecutor。Gateway 仅依赖运行时，App 注册具体 Actions handler。ToolRegistry 仅负责注册查找，ToolExecutor 负责执行和结果；System.runtimeInfo 实现从 App 移到 Tools/System。这使注册、执行和业务实现各归设计指定目录。

ChannelParser 管理生成期作用域；Channel 保存 Gateway 调度状态。现有 ChannelScheduler 负责 FIFO、容量、模块互斥、取消和完成；不为凑齐大纲重复创建 GhostShellScheduler。main 不改变为全局屏障。

保留根 Tests 和可选 ModelKit 包测试（AGENTS.md / SwiftPM 约束）。ToolResult、AgentInput 保留 AgentCore 共享契约以维持无环依赖；不创建同名副本。尚未实现能力不建立占位目录，均在差异表与模块 README 标 ❌。

验证：运行根检查、模拟器构建及无签名真机构建；实际结果见 Roadmap。本轮未验证真实麦克风或连续语音体验。

