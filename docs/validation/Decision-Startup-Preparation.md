# Decision 首页预加载验证

日期：2026-11-16。

首页前台准备新增当前选中的本地 Decision 资源。Agents 读取已保存路由，App 将选择闭包接入 ModelKit 准备步骤；D3 Edge/Lite、Gemma、Apple 系统模型均支持。无本地选择（云端或继承路由）不加载资源。沿用串行准备、交互期间延后、失活取消加入、配置变更重检和完成后的全量就绪复查。共享 Gemma 已就绪时不重复预热。

## 自动化证据

- `swift test --filter 'optionalLocalPreparation|localPreparationUses|modelPreparationSteps|homePreparation'`：14 项通过，覆盖无选择、四种本地 ID、未知 ID、读取失败、停止后拒绝，以及准备串行、迟到结果围栏、取消加入、重检和重试。日志 `/tmp/decision-preload-tests.log`。
- `./scripts/build-ios.sh`：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM 五目标通过。日志 `/tmp/decision-preload-ios.log`。
- 本地没有下载或运行真实 Decision 权重，本轮未安装真机；编译与替身测试不等于实际冷启动耗时、内存占用或物理设备验收。

最终定向复核：增加 readyD3ReportsItsSelectionAndDoesNotCallCloud 与 inputDecisionProtectsPossibleSpeechCommands 的独立运行，总计 16 项通过，日志 `/tmp/decision-preload-final-tests.log`。

完整 `./scripts/check.sh` 的架构检查、8 个 Python 测试及格式检查通过。全量并发 IntegrationTests 中上述两个 Decision 用例出现路由断言失败（独立复跑通过，未据此宣称全量通过），NexArm 的 slowTrackingDispatchExecutesOnlyTheNewestPendingTarget 也失败。AppWorkflowTests 延续 Writer/Web 的 injected Action declarations 缺失失败，随后超过 90 秒无输出，已终止本次进程树；后续独立原生 runtime 阶段未完成。日志 `/tmp/decision-preload-check.log`。`git diff --check` 通过。
