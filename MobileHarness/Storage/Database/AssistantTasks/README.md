# Assistant foreground tasks

assistant_tasks 保存平铺前台 scope，不含 parent、执行 Agent 或后台委派字段。唯一部分索引限制同时一个活跃 scope。Agents 负责取消并加入旧效果，仓库保存实际终态/end_reason，再允许新建。

摘要存 summary；来源由 assistant_messages.task_id 推导，source_revision/summary_revision 防止异步摘要覆盖更新后的事实。只有来源完整、终态且版本一致才能折叠，摘要失败保留原消息。MemoryAssistantTaskRepository 是显式测试/临时实例，不是 SQLite 故障回退。关系见[Database](../README.md)。

## Interfaces

AssistantTaskRepository/SQLiteAssistantTaskRepository 管理平铺前台任务；AssistantTaskSummaryRepository 提供来源及摘要读接口。MemoryAssistantTaskRepository 仅用于显式构造的内存上下文，不提供 Writer 或通信接口。摘要有效性和失效操作由本目录拥有，消息事务通过本目录内部操作更新。
