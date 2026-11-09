# Writer 委派接纳与业务拒绝

Agent 资源移除 backgroundTasks 及附带 Skill 白名单。Assistant 的 task.delegate 校验公开参数、消息权限和当前执行容量，直接封装原始用户输入和目标。Writer 使用认证来源、任务身份、可用容量与有效载荷接纳委派。委派不携带 Writer 专有业务契约，也不按目标内容进行静态筛选。通用任务信封继续支持其他固定能力的类型标记，固定角色继续拒绝未实现的后台请求。

Writer 私有控制模型根据任务判断执行、追问或拒绝。模型可在选择工作区前通过 finish(outcome: declined, summary: reason) 明确拒绝。拒绝走原有持久 writer.completion，使用 declined 业务事件和未成功的运行时终态。拒绝理由进入委派记录并交 Assistant 汇报，使用现有清理、去重和补发机制。运行时故障与接纳拒绝维持各自的含义。

影响 AgentConfigurations、AgentTasks、ChatWorker、固定任务接纳、Writer 执行和提示词、Agent JSON 与 Assistant 汇报教学。同步配置、Writer、通信和跨模块设计说明。回归验证无契约白名单的正常委派、接纳后模型拒绝、理由持久化、无工作区副作用以及旧授权释放。执行仓库全量检查与 iOS 模拟器构建。

移除全部 Agent 资源的同名字段，资源 schema 升为 v9。旧的模型 send 自填后台契约和 JSON 入口从工具教学及解析中移除。后台追加仍使用 task.send 已有的身份和追问绑定。

2026-11-09 完成。见 [验证记录](../validation/Writer-Delegation-Admission.md)。
