# ApplicationControl

## 职责与直接关系

拥有设置、模型资源、Provider、设备、导航及环境事实的确定性事务，不承担普通对话。UI/AgentBindings 提交类型化意图，Gateway 校验和投递，本角色发出固定函数调用，Actions 使用注入能力完成读写或呈现。Assistant 可以通过 application-control Skill 调用相同函数，不需要创建本角色的对话。

## 内部结构

| 文件 | 职责 |
| --- | --- |
| ApplicationControlAgent.swift | 根生命周期、接纳、环境及事务结果 |
| ApplicationControlWorkflow.swift | 查询、提交、配置和失败呈现的固定步骤 |
| ApplicationControlProcessing.swift | State、预处理及固定调用绑定 |

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
