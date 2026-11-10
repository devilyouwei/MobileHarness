# Agent 静态类别验证

日期：2026-11-10；分支 `codex/assistant-owned-speech`，基线 `d9069aa6` 加现有工作树。沿用已完成的 Assistant 语音内聚改动。

## 范围

对应[已完成需求](../completed/Agent-Categories.md)。

[分类契约](../../MobileHarness/Agents/README.md#agent-categories)定义七个生产角色的静态类别；[AgentDescriptor](../../MobileHarness/Agents/Support/Core/AgentDescriptor.swift) 提供必填 category。资源 schema v10 投影到 AgentConfiguration v8，通信收窄和有效能力替换保留类别。不引入新的调度、权限或模型策略。

## 验证记录

- 新增回归验证所有打包角色的分类和资源/配置一致性；用两种类别分别构造 Assistant 与 Memory，确认不按名称推断类别。
- 对资源和内部配置分别验证缺失、null、未知值、大小写、错误数值/数组和旧版本明确失败；验证通信收窄保留类别。
- 首次定向编译发现 UnifiedReceiptAgent 测试替身的推断式 Descriptor 初始化缺少新必填参数；补齐后重新执行。不以该失败作为通过结果。
- 定向测试通过：6 个测试函数，包含类别投影与非法输入的参数化场景。
- 首次完整检查因静态脚本仍要求资源 v9 而退出 1；同步脚本至 v10 并增加类别合法性校验后重跑。
- `./scripts/build-ios.sh` 退出 0：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个目标均 BUILD SUCCEEDED，Agent/Skill 与 Island 打包资源检查通过。
- 第二轮完整检查发现 CommunicationTests 和 RuntimeTests 的两处旧配置未携带类别，修正后单独回归通过；该轮亦出现跟踪目标时序断言和 ProviderDiscovery 取消断言失败，确认失败后中止该轮（退出 143），不计为通过。
- 跟踪测试单独复跑通过；取消测试单独复跑仍失败，检查确认替身在 UI 主线程异步传递取消前就被释放。补充底层取消观察握手后，四项定向回归全部通过（含返回工具成功/失败两种参数场景），未修改生产取消实现。
- 最终 `./scripts/check.sh` 退出 0：静态边界、6 项 Python 测试、Swift 严格格式、两阶段 Swift 测试及 plist 校验均通过。主要集成阶段报告 1115 项，最后运行时阶段报告 229 项；受环境限制的 opt-in skipped 项按下述边界单列。
- 新增/修改文档的本地链接目标及 `git diff --check` 通过。

工具链：完整 Xcode、Apple Swift 6.4、iPhoneSimulator 27.0 SDK。本机日志位于 `/tmp/mobileharness-category-targeted-final.log`、`/tmp/mobileharness-category-check-verified.log` 和 `/tmp/mobileharness-category-ios.log`，属于本轮本机输出，不是长期仓库制品。

## 验收边界

上述自动化阶段验证静态分类与既有行为回归，不调用真实模型或执行真机任务。完整脚本内受环境控制而 skipped 的模型/硬件用例不算验收通过；模拟器构建不等于安装或原生页面验收。

## 2026-11-10 真机安装

用户请求安装当前分支后，将 `codex/assistant-owned-speech` 工作树签名构建为 Mobile Harness 0.1.0（2026111005），使用现有本地签名配置和 `build/DeviceDerivedData`；未改动仓库签名设置。真机构建 BUILD SUCCEEDED，严格深层签名、33 项 Agent/Skill 资源及 Live Activity 扩展校验均通过。

原位更新到 iPhone 17 Pro，安装流水 6520；独立设备应用清单确认从 2026111004 更新为 2026111005，系统启动请求成功。未卸载应用或清空/直接修改用户数据。该包同时包含 Assistant 语音内聚和 Agent 静态分类；本次确认安装与启动，尚未进行语音效果、打断或页面交互验收。

本机证据：`/tmp/mobileharness-category-device-build.log`、`/tmp/mobileharness-category-device-install.json`、`/tmp/mobileharness-category-device-launch.json`、`/tmp/mobileharness-category-device-before.json` 与 `/tmp/mobileharness-category-device-after.json`。
