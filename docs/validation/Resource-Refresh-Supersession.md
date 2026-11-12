# 模型保存后快速离页的资源刷新误报

日期：2026-11-12。设备现场：用户确认模型保存成功，快速返回首页后出现黄色 Toast；截图记录 UI.ResourcePresentation.showResourceFailure / staleGeneration / handlerFailed。

## 修复与边界

ResourcePresentationAdapter 在根接纳和会话验证之后，将已被更高 refreshGeneration 替代的有效快照/错误呈现正常结束，不改写 UI、不 acknowledge，也不发起二次失败。当前批次仍显示真实结果和错误；零/未来序号、外来会话、根关闭继续拒绝。Provider 保存与回滚事务、Gateway 通用错误语义均未修改。

代码核对显示，旧批次被当作失败后 ApplicationControl 会用同一序号调用 showResourceFailure，形成截图所示二次错误。回归使用可控在途清单读取、较新批次和返回首页，验证生产 ApplicationControl/Gateway/适配器链路；不以此宣称已经操作真机复现。

## 自动验证

- 5 项定向测试通过：旧快照/旧错误不能覆盖当前 UI；最新错误仍显示；错误身份与无效批次仍拒绝；在途旧刷新经 Gateway 正常完成且后续刷新可用；原有查询失败、展示失败、保存/回滚失败用例仍通过。日志 `/tmp/mh-resource-supersession-focused.log`。
- 完整检查的新增两项回归均通过，AppWorkflowTests 194 项通过；边界检查、Python 7 项和格式检查通过。IntegrationTests 第一阶段 1152 项中有 6 个失败用例、14 个 issue：拍照动作组合/显式打开、拍照提示词教学/预算，以及既有 NexArm 时序断言。本次没有修改这些源码或测试，未将它们纳入此修复。完整日志 `/tmp/mh-resource-supersession-check.log`。
- 上述失败名称：allThreeNonBaseSkillsFitAndRepeatedLoadDoesNotDuplicateCatalog、taskOutputRulesReachDefaultAndPhotographyRequestPrompts、bundledTaskExamplesEmitSilentEntryAndSingleOrderedSpeech、assistantInstructionBudgetsKeepCatalogAndSafetyRules、cameraCompositeReturnsOnlyCaptureResultAndStopsOnPreparationFailure、slowTrackingDispatchExecutesOnlyTheNewestPendingTarget。
- 真机 Debug 签名构建 `2026111202` 成功（`/tmp/mh-resource-supersession-device-build.log`），未安装。`scripts/build-ios.sh` 四个 scheme 全部成功，52 个 Agent/Skill 资源及 Live Activity 校验通过（`/tmp/mh-resource-supersession-ios.log`）。完整检查后半段 LiveRuntimeTests 229 项通过；NativePresentationTests 没有完整终态，不能宣称全组通过。plutil 检查通过；完整脚本退出码 1，第一阶段失败如上。文档路径和 git diff --check 通过。

## 设备验证范围

检查期间发现工作区同时有独立的 Photo-Countdown-And-Explicit-Open 修改，拍照行为、提示词教学和预算测试未通过。本轮暂缓覆盖安装，保留原 iPhone 17 Pro 上的 2026111201，不将混合工作区的构建结果交付真机。保存后快速返回首页的实际触控验收仍需在修复版本上确认；没有调用真实模型或发送凭据。
