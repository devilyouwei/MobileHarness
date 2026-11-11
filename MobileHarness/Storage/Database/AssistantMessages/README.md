# Assistant messages

assistant_messages 每行对应一次实际发起的模型请求，保存完整业务输入、assistant response、工具调用/结果与 Action 结果。原始 Signal、Decision 和待发请求仅在有界内存中；discard 不落库。整批 Q 只创建一行，ReACT 另起一行，通过 caused_by_message_id 关联；task_id 只表示前台摘要 scope。输入键保证幂等，position 提供顺序，旧消息不能重绑到新任务。

AssistantMessageRepository/SQLiteAssistantMessageRepository 只读写 Assistant 消息。AssistantRecordStore 显式接收 AssistantConversationRepository、AssistantMessageRepository、AssistantTaskRepository/AssistantTaskSummaryRepository 与 ModelRequestLogRepository；AssistantHistoryStore 提供串行窗口修改、读 fence、checkpoint、分页和恢复。窗口保留等待 ReACT 的输入生命周期，不把 HTTP/图片重新载入运行上下文。

本目录拥有 AssistantRecords、消息 DTO、skills/Action 决策投影、通信来源关联、摘要感知分页和中断恢复。消息写入借用 AssistantTasks 内部操作使摘要失效，并在同一事务初始化日志或消费来源通信。SQL 不选择或读取 Writer 私有消息/任务。更新失败不伪造成功，checkpoint 错误保留供重试；写入等待上限 16，满时显式 busy。

关系和共享基础机制见[Database](../README.md)。

AssistantDecisionMetadata.states 保存当轮实际选择的 State 路径，随 decision_json 往返，不增加列或 schema 版本。字段缺失表示没有记录证据，空列表表示确实未选 State；清空 model_request_log 不删除该业务快照。完整 State 事实与图片仍属于可删除日志。

AssistantRecord.coordination 是实际请求携带的可选来源证据，包含采集时间、采用的 enqueue/interrupt、决策路径及批次成员ID；批次完整输入保留各成员来源/时间/决策，不为成员单独建行。单条原文上限16 KiB。重启仅将已发出的生成中请求标记 interrupted，不重放效果。

每次请求的完整业务文本保存于 user_input_json.requestText（首次请求和 ReACT 均在实际发起时写入），text 继续保存对应原始输入/观察，coordination 保存来源与批次。后续 checkpoint 保留 requestText；详情、窗口、分页预览和导出按本次 requestText 读取，不以原始主输入覆盖。清理完整调试日志不删除 requestText 或回复正文。旧多成员批次的完整详情仅在尚存日志包含相同成员ID集合时恢复实际批次文本；没有相应日志时保留既有原文，不重建或猜测。

准备中的模型请求标记 awaitingDispatch；checkpoint 跳过未发出的请求与没有已发请求的输入，模型发送回调才清除标记并在同一事务保存输入/请求。传输失败仍更新原请求行；预览仅返回持有 invocation 的记录。旧库迁移规则见 [Database](../README.md)。

模型生成结束的 checkpoint 更新已发请求的回复、生成终态及生成证据；Action journal 由执行轮次结算补写到原行。全双工 `task.end` 用同一历史写入边界确认已发请求、封存已关联的来源并提交任务摘要。已发请求继续更新原行，尚未发出的旧任务请求不能在结束后新建来源行。

AssistantInputCoordination 的可选 members 保存实际发起批次的成员 ID、来源、采集时间、分类及路径，沿用现有 coordination JSON。请求正文保存发送时的自然文本时间线，来源行只显示秒级本地时间。旧请求的原始证据保留，回放投影由 Agent 拥有。
