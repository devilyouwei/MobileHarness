# Assistant messages

assistant_messages 一行保存完整一轮 user input、assistant response、工具调用/结果与 Action 结果。ReACT 另起一行，通过本表 caused_by_message_id 关联；task_id 只表示前台摘要 scope。输入键保证幂等，position 提供顺序，旧消息不能重绑到新任务。

AssistantMessageRepository/SQLiteAssistantMessageRepository 只读写 Assistant 消息。AssistantRecordStore 显式接收 AssistantConversationRepository、AssistantMessageRepository、AssistantTaskRepository/AssistantTaskSummaryRepository 与 ModelRequestLogRepository；AssistantHistoryStore 提供串行窗口修改、读 fence、checkpoint、分页和恢复。窗口保留等待 ReACT 的输入生命周期，不把 HTTP/图片重新载入运行上下文。

本目录拥有 AssistantRecords、消息 DTO、skills/Action 决策投影、通信来源关联、摘要感知分页和中断恢复。消息写入借用 AssistantTasks 内部操作使摘要失效，并在同一事务初始化日志或消费来源通信。SQL 不选择或读取 Writer 私有消息/任务。更新失败不伪造成功，checkpoint 错误保留供重试；写入等待上限 16，满时显式 busy。

关系和共享基础机制见[Database](../README.md)。

AssistantDecisionMetadata.states 保存当轮实际选择的 State 路径，随 decision_json 往返，不增加列或 schema 版本。字段缺失表示没有记录证据，空列表表示确实未选 State；清空 model_request_log 不删除该业务快照。完整 State 事实与图片仍属于可删除日志。
