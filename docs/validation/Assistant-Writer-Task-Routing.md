# Assistant / Writer 任务路由验证

日期：2026-11-08。范围与实现计划见 [任务入口与作品归属](../requirements/technical/Assistant-Writer-Task-Routing.md)。本次在已有大量未提交修改的共享工作区上验证，不将其他并行修改计为本次实现。

## 自动化覆盖

- `writingSkillCannotBeLoadedOrGrantAssistantArtifactAccess`：writing 的 loadSkills/task.start 加载均失败，前台状态保持不变；Assistant Skill 目录不暴露旧作品库入口；教学包含平级选择和直接查找/打开委派。
- `writerLibraryOpensSavedWorksWithoutEditingAndRejectsAssistant`：Assistant 的 projects/open/delete 被拒绝；Writer 枚举、打开、删除真实作品；打开不改源文件、不产生草稿，非法身份与缺失作品失败。
- `writerBackgroundRoleUsesDirectGatewayAndPublishesActualArtifact`：保留创作、追问、取消、失败、通知和恢复场景；新增库查询经真实 Gateway/SQLite 收尾，确认不创建作品窗口/文件、不声称保存。
- 已有 `writerWaitingAndCompletionEnterAssistantModelFIFO` 覆盖有/无前台任务的独立委派与前台 scope 保持。
- 提示词示例解析、资源 JSON/路径和指令体积检查继续覆盖当前有效目录。

## 检查记录

- `./scripts/build-ios.sh`：退出 0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个目标成功；最终 28 项资源及 Live Activity 打包一致性校验通过。
- 最新代码的 LiveRuntimeTests / NativePresentationTests 自动化阶段：227 tests 通过（206.435 秒）。这不是手机物理设备验收。
- 最终 `./scripts/check.sh` 普通阶段：IntegrationTests 的 1086 tests 中 1 项失败，为未修改的 `slowTrackingDispatchExecutesOnlyTheNewestPendingTarget`（NexArmAimTests.swift:812，目标角度断言）；本次 Writer 14 场景、Writing 不可加载、库操作/权限、提示预算等均通过。脚本不能标记全绿。
- 第二次脚本的原生阶段仍在共享目录等待，因同版代码的 227 项原生测试已通过而终止重复等待；最终脚本退出 1。额外排队的专项重跑也取消，不能把该重跑记为通过；机械臂断言未修复、未独立复跑。plist 检查完成。
- 最终 `check.sh` 的边界检查、6 项 Python 测试、Swift 格式检查通过；本次没有修改机械臂代码或放宽其断言。
- 资源索引 JSON、引用路径、Writing 删除及 `git diff --check` 已核对。

初轮检查暴露旧的“身份指令不含 task.start”和“模型前必先打开窗口”测试假设，本次随新契约调整；初轮另见 UI 历史测试 `historyOrder` 解码错误。初轮 Simulator 主程序编译成功，但资源在构建期间发生修改，资源校验报 stale，不能据此声明完整脚本成功；最终版本重新执行。

## 真实模型和手机复验

自动化使用确定性模型替身，不能证明真实模型永不错误路由。本轮不调用付费模型，不宣称手机 UI 验收。

1. 无前台任务时要求“绘制流程图”或“把刚才的流程图改为卡通风格”：应直接 task.delegate，无同目标 task.start 或 writing 加载。
2. 要求“查找并打开之前的流程图”：Assistant 委派；Writer projects/open 使用真实结果，不创建替代空作品，不报告文件保存。
3. 正在进行独立拍照前台任务时委派写作：保留原前台目标及技能。Writer 忙碌时相关补充走 task.send，取消等待实际清理。
4. 查询不存在的作品、多个同名作品、取消查询与恢复：不编造标识或成功，错误/追问经 Writer 回报。
