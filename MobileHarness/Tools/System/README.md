# System · 系统信息工具

用途：提供运行配置说明。设计目标：与 App 装配和 ToolRuntime 注册解耦。

- ✅ RuntimeInfo.swift / SystemTools.runtimeInfo：返回原有固定配置说明，由 App 绑定 System.runtimeInfo。
- ❌ 真实健康探测、模型加载状态与设备诊断查询。

这是固定信息工具，不代表动态健康检查。修改实现、名称或目录时同步此 README。
