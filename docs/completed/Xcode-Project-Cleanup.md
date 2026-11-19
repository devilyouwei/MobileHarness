# Xcode 工程配置清理

## 范围与实施计划

2026-11-18：保留现有未提交目录迁移、对象 ID、三个构建目标及 SwiftPM 编译所有权。

- `MobileHarness.xcodeproj/project.pbxproj`：移除空 Frameworks 构建项及两个已不存在的 BasicInteraction 文件引用和空组；将 Recovered References 中的字符串目录归入现有配置文件所在组、Components 导航组，保持 Resources 成员不变。
- 将设备目标硬编码的 DEVELOPMENT_TEAM 从共享工程移除；若本地配置不存在则将原值保存至已忽略的 `Config/Local.xcconfig`，不覆盖已有本地选择。
- 仅移除与 `Config/Shared.xcconfig` 完全相同的目标设置，保留值不同的目标覆盖；不改变共享配置作用范围。
- 更新 Xcode 工程及 Config README，说明资源导航、共享设置和本地签名的所有权。没有跨模块接口或运行时行为变更，不调整应用总体架构。

## 验证

检查 plist 语法、文件路径、对象引用和构建阶段成员；对比清理前后有效构建设置。运行 `./scripts/check.sh` 和 `./scripts/build-ios.sh`，在验证记录区分自动化结果与未进行的真机验收。

## 状态

配置清理与技术文档同步已完成。五个 iOS 模拟器构建目标通过；完整检查中的 Swift 测试受已有 SwiftPM 进程锁阻塞，未获得结果。证据与未执行范围见[验证记录](../validation/Xcode-Project-Cleanup.md)。
