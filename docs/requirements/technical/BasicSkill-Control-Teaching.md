# BasicSkill 的 Task / Skill 控制教学

2026-11-08。用户确认按已讨论的结构优化 BasicSkill：说明 Task、Skill 的作用、选择方法、各 Action 的效果、生效时机与失败边界。保持通用教学，不引入具体业务例子或业务 Skill ID。

## 实施范围

- `Resources/Skills/BasicSkill/Instructions.md` 重组为概念、上下文、决策、控制动作、生命周期、反馈/失败六部分。Skill 包含指令、函数、State 选择和依赖；Task 保持持续目标，单次工作不因多轮模型请求就必须建 Task。
- 所有九个已注册 Action 各自说明用途和真实效果。load/release 改变后续请求，start 携带初始 Skill；end/cancel 的进入收尾与最终终态区分；delegate 接纳与业务完成区分；send 不创建目标；听说控制与 Task 独立。
- 修正“Task 持有 Skill 不可显式释放”的绝对说法：默认保留所需能力，任务终态自动清理；已确认不需要且允许释放的非基础根可显式释放，Task 仍存在。基础项和仍被其他根依赖的指定 Skill 不可释放，失败原子保留。
- 区分 Skill 事务失败与替换 Task 的多阶段失败。替换前预校验失败不改旧目标；清理失败拒绝启动；旧目标已收尾后新目标创建失败，不自动恢复旧目标。
- `Skill.json` 仅更新 description 和 revision；保持 schema、九项 useActions 的绑定/Channel、依赖及现有 useStates 不变。不增加重复参数 Schema、执行效果字段或业务路由。
- 保留少量通用目标的生命周期 XML 示例。参数与协议以 canonical Action / Core 为准；仅保留必要的角色文本映射和控制轮独占约束。
- 更新 `Resources/Skills/README.md` 与 `Tests/IntegrationTests/README.md`。测试核对打包教学、覆盖九个动作及状态来源，沿用真实状态转移/失败/Task 收尾回归；必要时补足缺口。没有生产 Swift、模块边界或跨模块流程变更，不新增目录。

## 验证

首轮实模暴露 skills JSON 嵌入 XML 的引号错误和状态误读，继续只补充通用编码/按字段含义读取事实的规则。旧 task-continue 夹具仍以 mediaID 校验已改为 previewID 的 Action，保留该次失败但不当作生命周期教学结果；在现有 qwen-workflows.json 增加仅等待用户选择并确认结束的通用任务完成用例，避免该夹具干扰，不修改摄影实现或掩盖旧失败。

运行定向资源/协议/Task 状态测试、`./scripts/check.sh` 和 `./scripts/build-ios.sh`；真实模型用既有 Qwen 入口复验跨能力发现与 Task 生命周期。共享工作区阻塞和无关失败独立记录，不能将旧通过结果当作本次结果。实际设备/网站接受度与合成执行反馈分开。

## 状态

revision 50 教学重组、JSON 描述与测试已实现；完整 check.sh、最终 36 项定向测试和四目标 iOS 构建通过。终轮实模 7/9，仍有单次拍摄就绪/重试及点头能力选择失败，旧摄影评估夹具也需对齐当前 previewID 契约，保留未归档。完整范围和证据见[验证记录](../../validation/BasicSkill-Control-Teaching.md)。此前发现教学的结果继续保存在[发现计划](Skill-Discovery-Before-Denial.md)及其验证资料中，不覆盖历史证据。
