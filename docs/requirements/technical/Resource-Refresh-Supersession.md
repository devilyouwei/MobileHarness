# 资源刷新被替代后的正常结束

2026-11-12：真机保存模型配置成功后快速退出设置页，出现黄色 Toast，记录为 UI.ResourcePresentation.showResourceFailure / staleGeneration。

## 现有问题与边界

ModelResourcesState 使用 refreshGeneration 防止迟到结果覆盖新状态。页面恢复/刷新与 ApplicationControl 的模型资源变更观察均可推进该序号。ResourcePresentationAdapter 目前将已被替代的刷新和错误呈现抛为 staleGeneration；ApplicationControl 又用同一过期序号呈现失败，导致二次异常。用户确认配置已保存成功，本修复不改变 Provider 持久化事务。

## 修改方案（先于代码）

- Actions/System/ModelResources/SettingsModelResourcesAdapter.swift：在校验调用会话、根呈现接纳后，将同会话、有效且小于当前序号的快照/错误呈现作为已被替代的 UI 更新正常结束，不写 UI、不 acknowledge、不生成失败；当前序号按原规则应用。无效/未来序号、错误会话、根不可用继续失败。取消仍传播。
- UI.ResourcePresentation.showResources 仍返回实际读到的清单；返回清单不承诺覆盖已更新的 UI。showResourceFailure 对已被替代的投影无需展示，正常完成仅代表呈现请求已处理，不代表原始业务失败变为成功。
- 不将所有 staleGeneration 或 handlerFailed 统一吞掉，不修改 Gateway 通用错误映射，也不取消已接纳的保存事务。最新有效刷新查询失败、保存失败仍保留原始失败与提示。
- Tests/IntegrationTests/ResourcePresentationTests.swift：使用真实 UI 状态和呈现适配器，覆盖旧快照/旧错误不覆盖新状态、最新错误可见、未来/外来会话拒绝；以可控在途查询经 ApplicationControl/Gateway 复现 newer generation 先完成的竞争，验证无二次失败调用且后续请求可用。
- 同步 Actions/System/ModelResources、Actions/UI/Resources 和测试目录 README；验证报告单列自动测试、构建与真机复现边界。不新增目录，不修改资源提示词。

执行 scripts/check.sh 和 scripts/build-ios.sh；相关定向回归与完整检查结果分别记录。原计划验证后交付真机；检查期间发现工作区同时正在实施 Photo-Countdown-And-Explicit-Open，拍照行为与提示词测试出现未通过项，因此本轮不覆盖安装混合版本。保留其他工作，不回滚或修复其内容；真机安装需待整合验证通过。

## 实施结果

2026-11-12：适配器与回归已实现，所属技术文档已同步；5 项定向回归、四个 iOS 构建和真机签名构建通过。完整检查的其他失败及暂缓安装原因见 [验证记录](../../validation/Resource-Refresh-Supersession.md)。
