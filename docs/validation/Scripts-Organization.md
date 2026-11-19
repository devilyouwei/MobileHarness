# 仓库脚本整理验证

日期：2026-11-18。范围见 [实施记录](../completed/Scripts-Organization.md)，逐文件职责见 [脚本清单](../../scripts/README.md)。

## 已验证

- 18项 Python 离线回归通过；全部脚本 Python AST / bash -n 通过。
- 下载 CLI 的帮助、非法 profile 拒绝、全部 catalog profile 与 Gemma Mac profile 路径解析通过；未下载权重。
- 架构边界、Swift 严格格式检查通过；工具与 Xcode 配置不存在本次迁移的旧脚本路径。
- sandbox 输入/输出清单重复生成结果一致；scripts README 本地链接有效；git diff --check 通过。
- `./scripts/build-ios.sh` 返回0：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM 五个 scheme 均成功；Agent、Live Activity 与本地化资源验证通过。

## 全量检查限制

`./scripts/check.sh` 的普通 IntegrationTests 执行1200项，报告9个 issue，包括旧 Speech 文案断言、Decision 超时、机器人请求过期和 tracking 时序断言。AppWorkflowTests 还报告缺少 injected Action declarations、识别模型列表及 Web 截图状态断言失败；Writer 取消用例的无超时等待未结束，终止了本次 AppWorkflow 测试子进程以继续后续阶段，普通测试未完整完成。这些业务测试没有在本次工具整理中修改，不将全量检查记为通过。

本地完整日志：`/tmp/mh-scripts-check.log`、`/tmp/mh-scripts-ios.log`。未执行真实模型推理、下载、模拟器 UI 操作或真机验收；构建成功不替代这些验收。

最终 `check.sh` 返回1。后续 LiveRuntimeTests 串行阶段完成228项，1个 issue：soundSourceSlowSubscriberDoesNotBlockFollowingDirections；末尾项目和四个 plist 校验均通过。该命令未取得原生 UI 完整验收结论。
