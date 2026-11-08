# 前台任务启动同时加载 Skill

2026-11-08，用户要求恢复 task.start 携带 Skill，并提供无需紧接 loadSkills 的示例。

## 核查与设计

TaskActions 的可选 skills 参数、BasicSkill canonical 绑定及 AgentTaskSkillState 原子启动/加载均存在。问题是 BasicSkill 示例展示不带 skills 的启动，再教下一轮 loadSkills，削弱了已有能力的教学。

- 仅修订 Resources/Skills/BasicSkill/Instructions.md 与 Skill.json revision：创建前台任务时携带已知必要的非基础 Skill ID 数组；已有加载项可交给任务保留。成功反馈后的下一轮直接使用已提交的函数，不重复 loadSkills。
- 提供单 Skill、多 Skill 的完整 XML 例子；仅在后来新增缺失能力、或不创建 Task 的单次工作时单独 loadSkills。保留控制 Action 独占一轮、提交后才生效的边界。
- 通用 Task/Skill 教学由 BasicSkill 拥有，不写入 Assistant 身份或 Writer 私有提示。task.delegate 仍为其他 owner 的平级入口，不携带 Skill 或创建前台包装。
- 不修改生产 Swift 实现或 canonical 参数；在 PromptTemplateTests 从实际资源提取示例，经过解析、声明校验及状态提交，验证下一轮已含所需函数/私有 Skill 正文、没有额外 loadSkills；未知 Skill 仍原子拒绝。沿用真实 Assistant/Gateway 的既有启动携带 Skill 回归。
- 同步 Skills、Task 和测试 README；执行专项回归、check.sh、build-ios.sh，区分确定性测试与真实模型/真机验收。不新增目录，保留其他工作区改动。

## 完成

已修订 BasicSkill 教学与 revision、增加实际资源示例回归并同步技术说明。8 项专项、全仓检查及四目标 iOS Simulator 构建通过；生产 Swift 未修改。证据及实模/真机边界见[验证报告](../validation/Task-Start-Initial-Skills.md)。
