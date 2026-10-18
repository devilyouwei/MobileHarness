# ApplicationControl

## 职责与直接关系

拥有设置、模型资源、Provider、设备、导航及环境事实的确定性事务，不承担普通对话。UI/AgentBindings 提交类型化意图，Gateway 校验和投递，本角色发出固定函数调用，Actions 使用注入能力完成读写或呈现。Assistant 可以通过 application-control Skill 调用相同函数，不需要创建本角色的对话。

## 内部结构

| 文件 | 职责 |
| --- | --- |
| ApplicationControlAgent.swift | 根生命周期、接纳、环境及事务结果 |
| ApplicationControlProcessing.swift | State、预处理、固定调用绑定及异常分类/提示策略 |

状态保存待执行调用、类型化环境值与事务关联；Builder/执行器只使用已提交快照。具体资源、Provider 和设备函数契约见 [System Actions](../../Actions/System/README.md)，UI/原生实现由 App 注入。

## 输入与事务流程

[Agent.json](../../Resources/Agents/ApplicationControl/Agent.json) 声明 model.resource.intent/state/hostFailure、app.environment/interaction、provider.settings/discovery 的可信来源及 task.progress/result 通信。baseSkills 为 application-control；当前模型绑定是导航、状态查询、蓝牙操作与资源下载/取消，机械臂对话动作属于 robot-interaction。固定设置/设备实现与模型暴露分别注册。

资源刷新验证 root session/revision，读取并提交有界库存；失败先调用相应失败呈现，再释放事务 gate。下载/取消/删除的接纳不是安装或物理完成，结果保留实际状态。偏好先持久化，再应用 speech binding；后续失败不伪造回滚。Provider 凭据通过私有 requestID 暂存，不出现在 Signal/模型上下文中。

环境 publish 单向，订阅方拒绝不反馈发送方；有确认的 send 只用于声明的独立业务工作。导航展开、滚动与未提交草稿留在 UI，提交后的业务调用有根 owner，独立于页面。

## 容量、取消与失败

最近 4096 条 Signal 证据/消费批次滚动保留并累计淘汰计数；pending 调用、任务和当前环境独立保存，证据不是执行队列。输出容量 256、状态提交等待及通信消费者有界，溢出明确拒绝。原子提交失败保留原状态并传播，不重放不确定效果或关闭无关根 scope。

取消加入已接纳调用和呈现清理；重启不恢复热队列或重放设备动作。仓库只通过中立协议注入，运行时状态位于进程内存；设置/资源偏好、凭据及设备事实按各自 owning 模块持久化。

## 待实现

- 共享 push 型资源状态源及对应的观察适配能力。
- 真实模型调用、原生配置/设备交互与后台资源传输的独立验收。

## Storage 依赖

✅ 存储访问使用独立的 State、Cache、Database 和 Files 接口；App 注册根实例，消费者通过构造器获得所需能力。存储容器不接管本目录的业务验证、执行和完成语义。

## ApplicationControl 异常展示

✅ 已实现：ApplicationControl 声明 container.failure 与 runtime.failure/runtime 订阅，以确定性代码校验、合并有界异常证据、选择分类和提示文案，通过内部 UI.RuntimeDiagnostics.recordFailure 调用提交展示；不调用模型、不写 Storage。异常展示回执独立于原失败完成语义，展示失败保留证据且不递归生成提示。

异常 Signal 通过独立、无持久化的被动接纳路径处理，允许 running/paused，拒绝错误来源、会话、执行作用域及过期信封。最近 128 个事件键保存合并版本；内部呈现调用最多 128 个未完成，输出沿用 256 上限，超限明确拒绝。容器计数仅接纳增长，runtime 事件按 ID 去重。首次发生且距离现在 −5…15 秒的无 callID 异常可提示，历史、重复及调用关联异常只留记录。缺少专用提示时使用有界原始详情；UI 保留自身展示过期与去重防线。

内部呈现失败保留最多 128 条有界回执详情，Gateway 原始失败记录仍可观察；不自动重放效果，不递归提示或终止无关设置事务。停止清空接纳状态，迟到 Signal 被拒绝。应用尚未建立角色运行图时由 App 保留启动错误展示；此路径不保证关闭期间的异常还能送到已停止角色。

## UI 全量容器化

✅ 应用级 UI 状态由八个子容器统一创建，消费者注入所需 Presenting 接口并提交 UI 自有值，不直接写字段。App 注册并管理同一 UI 根；原业务身份/版本校验、原生完成和基础库依赖边界保持。跨模块连接迁移仍是独立待办。
✅ ModelResourceInteractionWorkflow唯一拥有下载源防抖任务和共享初始恢复任务；已恢复页面刷新库存与声音偏好，不覆盖端点草稿，明确失败后的restore允许重试。编辑意图更新草稿、合并最新端点，忙碌完成事件驱动续存而非轮询；停止关闭接纳、取消并加入自有任务，不重放失败保存。

✅ 资源操作接纳时调用 beginRefresh 使旧库存刷新失效；该处不发起按代次读取，显式丢弃返回的 generation，实际刷新路径继续校验代次。
