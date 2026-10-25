# State 公开寄存器与 useState 实施

> 架构替代说明：本文保留原共享寄存器需求与历史完成证据。当前实现迁移至 [Container 状态与模型上下文](technical/Container-State-Context.md)，不再使用 StorageState、公共 task 或 Skill v2。后续验收以新需求及当前源码 README 为准。


状态：✅ 本轮代码与专项自动化已实施；❌ 真实模型、原生 UI 与物理设备验收待执行。替换旧资源快照计划与完整 AgentContext 托管方案；历史证据保留在 validation/history。

State 仅发布 LLM 所需的有限公开事实，不集中保存程序执行状态。保留版本、代际、类型化端口、一致快照、容量和观察；增加名称/应用或 Agent 会话作用域及编码投影。AgentContextRepository 持有私有内存，保留事务、验证与提交测试钩子。

首批 camera：enabled/running/selectedFacing/busy/needsSettings/displayedMediaID/savedMediaID；robot：connected/controlAvailable；task：goal/status（running/waitingUser），无任务为 null，内部收尾保留最近公开状态。Task 业务权威仍在 Agent，按会话发布，结束关闭。未知/不可用明确表达；发布失败失效并报告。

Skill schema v2 的 useState 必填，替代 contextFields；BasicSkill=[task]、Photography=[camera]、RobotInteraction=[robot]、其余=[]。展开依赖合并去重，验证声明；每次请求与 ReACT 重新读取绑定作用域的快照，生成唯一 CURRENT STATE 独立 system 数据消息，放在完整历史之后、当前输入/观察之前；若末尾为 native Tool 结果，放在完整结果组之后。稳定规则/目录位于首条 system，历史保存实际请求。移除旧相机及 Task/Skill 管理信息 user 消息，保留真实输入、动作反馈与 native 配对。

公开名称按声明解析，禁止跨作用域回退。同地址唯一；默认 256 项/64 Scope/64 观察者，每值 8 KiB、每 Skill 16 名称、每请求 32 名称、状态块 16 KiB。失败显式传播，取消/关闭失效旧端口。事实生命周期独立于 Skill/页面。

本轮不新增目录/目标/第三方依赖（ActionBindings 显式使用既有 StorageState 目标），不实现 Trigger、逐转换日志、完整写入源治理或全量 Signal 重构，不改变 SQL/文件格式，不自动提交合并。

验收覆盖私有状态移出、注册/版本/编码/容量、作用域隔离、每轮刷新、Task 生命周期与发布失败、Skill 依赖/释放、设备真实事实与部分失败、watch 不触发执行。运行 scripts/check.sh、scripts/build-ios.sh，区分全量失败、CoreAI Simulator 限制、设备构建及真实验收。


## 实施对账

- ✅ AgentContext 私有 actor 内存；公开名称、作用域、编码投影及绑定读取；camera/robot/task 首批事实发布。
- ✅ Skill v2/useState、每轮新快照与唯一系统块、请求证据及旧 user 状态入口清理。
- ✅ observe 保留初始/最新通知，不触发模型；发布失败保留业务提交并失效公开读取。
- ✅ 设备目标构建和资源打包通过；❌ 全量集成时序失败、Simulator CoreAI 限制及真实验收缺口见 [验证记录](../validation/Validation-History.md#2026-10-17--state-public-register-and-usestate)，不以专项通过替代全量结论。
- ❌ Trigger、完整写入源治理和更多事实属于后续范围。
