# ADR 0001 原生模块化 Runtime

状态：采纳。日期：2026-09-22。

使用 SwiftUI App + 本地 Swift Package，不引入项目生成器。提交原生 `.xcodeproj` 和共享 scheme；共享构建设置进入 xcconfig，本地签名覆盖文件不提交。这样首次安装 Xcode 后即可打开工程。

工具链基线为 Xcode 27 / Swift 6.4，语言模式 Swift 6；部署目标 iOS 18，以覆盖更多实际手机，新 API 按 availability 与硬件能力启用。Package 支持 macOS 15 用于核心测试，不意味着已提供 macOS App。

UI 默认 MainActor，核心 Package 不设置全局 MainActor；每个 Agent actor 独立隔离。用协议注入模型和平台能力，以确定性演示驱动基础测试。没有真实 adapter 时不模拟为“能力可用”。

暂不引入第三方依赖、模型权重和云凭证。选择具体模型与设备后再评估兼容性、许可证和资源开销。参考 [Swift 6 数据竞争安全](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/)与 [Apple 工具链支持表](https://developer.apple.com/xcode/system-requirements)。
