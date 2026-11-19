# Tests 目录整理验证

日期：2026-11-18。此次只调整测试归属、路径、编译清单和开发入口；没有修改生产 Swift 行为。

## 已完成静态检查

- 保留原有 18 个 SwiftPM 测试 target、依赖和 183 份测试 Swift 源码的编译成员，源文件无重复归属；生产 target 清单保持一致。
- 包含独立 DecisionDecoder 在内的 184 份 Swift 源文件，函数声明名称和顺序均与迁移前一致。
- Xcode Tests 导航按物理职责目录分组，297 个测试源/文档/资源引用存在且不重复；保留原文件引用身份、target 和 build phase 配置。
- Tests 内 Markdown 相对链接全部存在；历史文档引用已退役的生产文件属于原有记录，不冒充当前入口。
- 三个 Python 离线套件共 17 个用例通过。根包和独立 Decision 包的 manifest 均可解析。
- 17 个 Swift 源相对根和 8 个 Python benchmark 仓库根定位保持原义；所有测试 Python 源码可解析，Qwen、Writer 和独立 Decision CLI 的帮助入口可运行。
- 边界检查的路径集合优化通过 12 个文件、目录和符号链接排除/发现组合核对；排除语义与原实现一致。
- `git diff --check` 通过。

## 完整检查

`scripts/build-ios.sh` 已退出 0，5 个 Simulator scheme 全部构建成功；保留已有编译警告，不将构建成功当作设备验收。

`scripts/check.sh` 最终退出 1，不能标记为通过。边界、17 个 Python 用例、严格 Swift 格式和最终五个 plist/project 校验通过。Swift 编译完成；普通阶段与串行阶段均已启动，普通阶段的 AppWorkflow 子进程因下述无界等待被终止。

| 检查范围 | 实际结果 |
| --- | --- |
| 普通 IntegrationTests | 1198 个测试，4 个 issue：3 个英文提示词断言和 1 个跟踪目标断言失败。 |
| AppWorkflowTests | 日志记录 21 个失败的测试声明；Writer/Web 缺少注入的 Action declarations，另有 recognition.modelIDs 预期不匹配。未获得完整完成汇总。 |
| 串行 IntegrationTests / LiveRuntimeTests | 228 个测试，1 个 issue：soundSourceSlowSubscriberDoesNotBlockFollowingDirections 等待声源超时。 |
| NativePresentationTests | 日志记录部分用例完成，但没有完整 suite 汇总；不据此宣称完整原生 UI 验收通过。 |
| 跟踪用例单独复跑 | slowTrackingDispatchExecutesOnlyTheNewestPendingTarget 通过（0.067 秒）；全量失败仍保留，不据单项重试认定时序问题已根治。 |
| 声源用例单独复跑 | soundSourceSlowSubscriberDoesNotBlockFollowingDirections 仍失败（4.073 秒），原因相同。 |
| 迁移后测试发现 | 完整 Xcode 下 `swift test list --skip-build` 退出 0，列出 18 个 target 的 2116 个测试标识。 |

英文提示词失败仍要求 `becomes audio on independent Speech` 等旧原文；工作区在此次整理前已有的 Instructions.md 改动已经替换该句，本次没有撤回用户改动或改写断言。21 份 AppWorkflow 源文件、AgentConfigurationTests、NexArmAimTests 和 SoundSourceTests 与迁移前快照逐字节相同，生产 Swift 源码没有本次改动。

`writerCancellationDuringBackoffDoesNotStartAnotherRequest` 在任务已因缺少声明失败后，仍用无截止时间的 `while await model.requests.isEmpty` 等待首个请求。AppWorkflow 子进程约运行 2 分半仍未结束后被显式 SIGTERM；主检查继续执行串行阶段和 plist 校验。该阶段属于未完整运行，不能记为通过。

日志位于 `/tmp/mobileharness-tests-check.log`、`/tmp/mobileharness-tests-ios.log`、`/tmp/mobileharness-tests-tracking-recheck.log`、`/tmp/mobileharness-tests-sound-recheck.log` 和 `/tmp/mobileharness-tests-final-list.txt`。日志为当前主机临时证据，核心结果已在本文保存。

此次整理不修复上述业务断言、配置注入和等待生命周期问题；它们需要独立修复及验证。目录、编译成员、入口与引用迁移已完成，映射见 [整理记录](../completed/Tests-Organization.md)。

## 证据限制

迁移前利用旧构建产物执行 `swift test list --skip-build` 时，CommandLineTools 的测试助手出现 signal 5，未取得完整基线测试发现清单。因此以源码成员、函数声明和迁移后的实际测试结果分别核对，不将不完整列表声称为通过。

保留已有未提交实验、提示词和测量记录；历史 JSON、源哈希和原始设计 Word 未改写。严格匹配旧源码哈希的历史回放需使用对应提交，不绕过校验。

本次不运行真实模型、云服务、原生触摸或物理设备验收。既有模型遵循、相机/Photos、麦克风/声源、声学竞争、持续 BLE/USB/视觉跟踪、原生 UI，以及可注入 Skill 依赖图的验收范围保持独立。
