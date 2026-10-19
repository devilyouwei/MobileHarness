# Memory

## 职责与直接接口

处理历史读取、归档、删除、展示与独立标题生成事务，不生成普通对话。UI/AgentBindings 的 history.intent 经 Gateway 进入；Memory 发出固定调用，Actions 通过注入的 StorageChat/呈现端口执行，结果回原事务。Assistant 的 history-query 查询 Actions直接使用同一批函数，不需要把用户对话转发到 Memory。

## 内部结构

| 文件 | 职责 |
| --- | --- |
| MemoryAgent.swift | 接纳、生命周期与事务结果 |
| MemoryHistoryWorkflow.swift | 固定调用、关联与历史步骤 |
| MemoryProcessing.swift | State、预处理及上下文 |
| ConversationTitleGenerator.swift | 仅生成标题的独立模型请求 |

运行时保存调用/事务关联，不把标题请求写入普通对话。历史记录接口由 [StorageChat](../../Storage/Database/Chat/README.md) 拥有；函数与参数由 [History Actions](../../Actions/History/README.md) 拥有。

## 历史与标题流程

归档先提交，再独立生成标题；标题失败不撤回已提交归档。标题从全会话等距抽样至多 32 轮，每个 user/assistant 摘录至多 80 Characters，发两条消息、64-token 输出预算、temperature=0，30 秒取消并加入的截止时间。只接受明确 stop、单行非空且不超过 80 Characters 的文本；拒绝动作、Tool、截断和空结果，不执行模型输出。

Cloud 非思考参数由 [OpenAI 请求编码器](../../ModelKit/Language/LLM/OpenAI/README.md#non-thinking-request-policy) 拥有；Memory 不写 vendor 字段或用更大预算自动重试。定向结果必须匹配原输入、会话和调用身份，独立标题工作由根 owner 取消/清理。

## 注册、状态与失败

[Agent.json](../../Resources/Agents/Memory/Agent.json) 声明 history.intent 订阅、定向 task.progress/result 和 baseSkills=history-query。固定 startNew/summarize/delete/showHistory 调用在 workflow 注册；模型查询绑定由 Skill 声明。没有普通用户文本 Chat worker，也不把函数能力当作其他角色的历史权限。

最近 4096 条 Signal 证据/消费批次采用有计数的滚动保留；调用、任务和历史记录独立保存。输出容量 256、状态接纳与通信容量按 [公共机制](../Support/README.md) 处理。提交失败不执行依赖步骤，取消加入已接纳工作，重启标记未完成业务记录中断而不重放。角色热状态在内存，业务事实通过注入的仓库持久化。

## 待实现

- 超出记录事务与标题生成范围的语义记忆能力。
- 历史原生交互、真实模型标题与端到端取消/恢复验收。


## 历史只读请求接入

✅ UI 的记录分页、消息、归档及授权图片读取也经 MemoryHistoryIntent.query 的实际 Gateway/Memory 接入；不再由 UI 请求适配器直接读仓库。MemoryHistoryReadRequests 为根持有的类型化只读请求暂存，最多四个请求，每个请求一个结果等待者；Signal 只携带随机 ID，结果保留规范仓库返回值。请求/结果有界，120 秒未返回明确超时，取消/停止加入实际读取，迟到结果不更新 UI；不新增模型函数或重放副作用。

## Storage 依赖

✅ 存储访问使用独立的 State、Cache、Database 和 Files 接口；App 注册根实例，消费者通过构造器获得所需能力。存储容器不接管本目录的业务验证、执行和完成语义。

## UI 全量容器化

✅ 应用级 UI 状态由八个子容器统一创建，消费者注入所需 Presenting 接口并提交 UI 自有值，不直接写字段。App 注册并管理同一 UI 根；原业务身份/版本校验、原生完成和基础库依赖边界保持。跨模块连接迁移仍是独立待办。