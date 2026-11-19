# Xcode 工程配置清理验证

日期：2026-11-18。验证基于包含既有 Tests/experiments 迁移的工作区；只对本次清理前后的工程对象进行比较。

## 通过

- `plutil -lint MobileHarness.xcodeproj/project.pbxproj`：语法通过。
- 对比清理前后解析出的工程对象：三个 Target、Sources、Resources、Copy Files、Shell Script 阶段以及 SwiftPM 产品依赖未改变；Frameworks 仅移除没有 fileRef/productRef 的空项。
- 全部 SOURCE_ROOT 文件路径存在，检查的对象关联均有效，剩余 PBXBuildFile 均关联文件或产品。
- 两个字符串目录对象 ID 和 Resources 成员保持不变，仅改变导航父组。
- 合并 Shared.xcconfig 后比较八个构建配置：除签名改为本地配置外，有效值保持一致。删除扩展 Debug/Release 重复的 GENERATE_INFOPLIST_FILE，保留其他目标覆盖。
- 本地签名配置被 Git 忽略。技术 README 相对链接及本次文件的 `git diff --check` 通过。
- `./scripts/build-ios.sh` 退出 0：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM 五个目标均 BUILD SUCCEEDED；最终 App 的 73 项 Agent/Skill 资源、Live Activity 嵌入和中英文本地化验证通过。

## 完整检查限制

`./scripts/check.sh` 的边界检查、18 项 Python 测试和 Swift 格式检查通过。随后 SwiftPM 报告 `.build` 被另一条已有 Swift 测试进程占用，本次检查在锁等待阶段以 143 退出；未获得本次 Swift 自动化测试结果，不能将完整 check.sh 标记为通过。已有进程不属于本次清理，不据此声明其结果。

本次会话原始日志：`/tmp/mobileharness-pbx-cleanup-check.log`、`/tmp/mobileharness-pbx-cleanup-build.log`，属于本机临时证据，不纳入版本控制。

## 验收边界

未执行签名实机安装、真实模型推理、原生 UI 交互或物理设备验收。模拟器构建和资源校验不代表这些能力已验收。
