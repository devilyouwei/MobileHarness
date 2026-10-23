# Agents Support — 跨角色共享机制

## 职责与编译边界

本目录只提供跨角色可复用的输入／执行关联、故障聚合、配置资源加载、Chat、Context 和通信值。角色私有输入、策略、会话和观察归角色目录；具体生产图与通信目录归 Agents 根级。

Support/Core 独立编译为 AgentCore，仅依赖 Foundation。其余文件由 Agents 编译，使用所需的基础能力及 Actions／Gateway 公开接口，不创建基础根、不操作原生设备，也不代替角色消费输入。

## 文件与子目录

| 文件／目录 | 职责 |
| --- | --- |
| [AgentConfigurations.swift](AgentConfigurations.swift) | 有界不可变配置资源、函数声明安装与版本校验 |
| [AgentSkillLoader.swift](AgentSkillLoader.swift) | Skill 依赖组合与声明投影，不管理角色实例 |
| [AgentUIRequests.swift](AgentUIRequests.swift) | UI 请求订阅、真实取消、执行输出关联与回执完成 |
| [AgentInputMetrics.swift](AgentInputMetrics.swift) | UI／PCM／相机输入的可选汇总诊断，不保存内容或创建队列 |
| [ContainerFailureChannel.swift](ContainerFailureChannel.swift) | 原始故障聚合、有界投递及原生错误分类 |
| [Chat](Chat/README.md) | 模型请求、解析、真实结果屏障、历史与续轮 |
| [Context](Context/README.md) | 私有事务、Task／Skill 状态、固定任务结果加入和有限公开投影 |
| [Communication](Communication/README.md) | 跨角色消息值及固定任务的协议中立准入机制 |
| [Core](Core/README.md) | 身份、输入／输出、生命周期、队列、解析和通用运行契约 |

## 输入、执行与完成

角色持有 consumeUI 的长期订阅，普通请求与控制请求分别顺序消费。订阅接纳请求、构造带请求身份与代际的 ProcessingContext 并调用角色类型化处理；请求取消关联实际处理任务。任一消费流结束会取消并加入另一消费流，关闭时使用原 token，避免关闭替代消费者。单次 UI 处理的公共截止时间为 120 秒。

AgentUIExecution 最多关联 64 个活跃请求，每请求最多暂存 64 个输出；输出归当前 UI 事务或原输出流，不能双路发布。执行端口在角色 start 前绑定、stop 后释放。共享机制无角色路由表、InputGateway 外部输入入口或私有业务 JSON 解码。

固定任务的来源约束与载荷解释边界见 [Communication](Communication/README.md#固定任务准入)。Chat 的角色会话控制接口见 [Chat](Chat/README.md#角色接口)。

## 故障与诊断

ContainerFailureChannel 保存 128 条记录和原始 Error，待投递项最多 64 个；记录和待投递项分别淘汰最旧项并累计计数。相同故障合并发生次数和时间，取消及原生生命周期控制可抑制投递。单 worker 经注入回调投递，失败写入该记录的 deliveryFailure，不递归上报；重连会重新排入失败记录。最多八个观察者，各保留一个最新快照。stop 关闭接纳、取消并加入 worker，再结束观察。

运行执行失败的快照由 [Gateway/Output](../../Gateway/Output/README.md) 拥有，不进入本目录的独立待处理队列。具体装配将两类故障交给 ApplicationControl 制定呈现策略，启动前错误由 App 处理。

AgentInputMetrics 中的 ContainerInputMetrics 在 `-direct-input-measurements` 下记录汇总耗时，在 `-direct-input-diagnostics` 下记录拒绝角色／来源／契约；不输出媒体、用户文本或业务身份，不增加媒体缓冲或改变接纳策略。

[Agents 根级装配与角色关系](../README.md) · [总体设计](../../README.md)
