# Assistant foreground tasks

assistant_tasks 保存平铺前台 scope，不含 parent、执行 Agent 或后台委派字段。唯一部分索引限制同时一个活跃 scope。Agents 负责取消并加入旧效果，仓库保存实际终态/end_reason，再允许新建。

摘要存 summary；来源由 assistant_messages.task_id 推导，只有来源完整、终态且版本一致才能折叠。全双工 `task.end` 在一笔 SQLite 写入中校验结束请求及来源，写入 completed、end_reason=task.end、结束时间与摘要。结束后固定来源成员；已有成员补写生成或执行证据时同时推进两个版本。其他摘要仍按来源内容变更失效。原始 Message 保留。MemoryAssistantTaskRepository 是显式测试/临时实例。关系见[Database](../README.md)。

## Interfaces

AssistantTaskRepository/SQLiteAssistantTaskRepository 管理平铺前台任务；AssistantTaskSummaryRepository 提供来源、折叠读取及显式结束事务。MemoryAssistantTaskRepository 用于显式构造的内存上下文。摘要有效性和失效操作由本目录拥有，消息事务通过本目录内部操作更新。
