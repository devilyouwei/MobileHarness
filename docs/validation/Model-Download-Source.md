# 模型下载源验证（2026-11-14）

范围：移除 Agent Brains 的独立下载设置保存按钮，首次恢复默认源按系统首选语言选择，保留已保存偏好与在途下载源快照。需求见 [实施计划](../requirements/technical/Model-Download-Source.md)。

- `scripts/build-ios.sh`：通过；MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四目标及应用资源校验通过。
- `scripts/check.sh`：架构边界、7 项 Python 测试及 Swift 格式检查通过。完整测试未通过：IntegrationTests 的 D3 路由及 NexArm 最新目标断言失败；AppWorkflowTests 多个 Writer/Web 用例报告缺少 injected Action declarations，随后运行器无进展，被停止以继续原生运行时阶段。这些路径不在本次改动范围，不将结果当作通过。
- 新增语言默认源测试：zh、zh-Hans-CN、zh-Hant-TW、zh_CN、en-US、fr-FR、缺失语言共 7 用例通过；各自验证用户保存的自定义源优先。
- 新增在途快照测试：下载请求暂停期间保存不同源，原请求仍使用 Hugging Face 源，后续请求使用镜像源；通过。
- 首次脚本运行受沙箱缓存写权限阻止，获得执行权限后重试。
- 未进行真机页面交互或真实网络模型下载；替身测试与模拟器构建不代表此类验收。

本次日志：`/tmp/mobileharness-source-check.log`、`/tmp/mobileharness-source-ios.log`；临时日志不是仓库永久附件。

## 最终验证

完整检查退出码为 1，保留上述首轮失败与 AppWorkflowTests 中止记录。后续 LiveRuntimeTests 的 228 项测试通过，plist 校验通过。

单独复跑退出码为 0：语言默认源（7 个参数用例）、在途快照、下载前自动保存及保存失败阻止下载全部通过。D3 路由与 NexArm 最新目标断言在单独复跑中通过，但不据此抹除全量运行失败。复跑日志为 /tmp/mobileharness-source-focused.log。

最终 git diff --check 通过。

## 下载源名称简化

共享模型页面和中英目录统一显示 Hugging Face，相关下载源说明同步移除 Official／官方修饰。地址、内部标识和下载行为不变。与 Execution Log 标题一起通过语言专项测试和最终 iOS 四目标构建，详情见 [语言验证](App-Localization.md)。
