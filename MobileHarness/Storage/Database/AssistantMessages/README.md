# Assistant messages

assistant_messages 每行对应一次实际发起的模型请求，保存完整业务输入、assistant response、工具调用/结果与 Action 结果。原始 Signal、Decision 和待发请求仅在有界内存中；discard 不落库。整批 Q 只创建一行，ReACT 另起一行，通过 caused_by_message_id 关联；task_id 只表示前台摘要 scope。输入键保证幂等，position 提供顺序，旧消息不能重绑到新任务。

AssistantMessageRepository/SQLiteAssistantMessageRepository 只读写 Assistant 消息。AssistantRecordStore 显式接收 AssistantConversationRepository、AssistantMessageRepository、AssistantTaskRepository/AssistantTaskSummaryRepository 与 ModelRequestLogRepository；AssistantHistoryStore 提供串行窗口修改、读 fence、checkpoint、分页和恢复。窗口保留等待 ReACT 的输入生命周期，不把 HTTP/图片重新载入运行上下文。

已接纳的输入通过 `prepareAdmittedInput` 在历史写门内准备。调用方提供当前对话和输入 ID，Store 核对输入仍可准备，再更新该输入的请求。其他消息或执行反馈在同一对话中的写入可以与准备交错。新建历史记录仍使用读版本令牌。

本目录拥有 AssistantRecords、消息 DTO、skills/Action 决策投影、通信来源关联、摘要感知分页和中断恢复。消息写入借用 AssistantTasks 内部操作使摘要失效，并在同一事务初始化日志或消费来源通信。SQL 不选择或读取 Writer 私有消息/任务。更新失败不伪造成功，checkpoint 错误保留供重试；写入等待上限 16，满时显式 busy。

关系和共享基础机制见[Database](../README.md)。

AssistantDecisionMetadata.states 保存当轮实际选择的 State 路径，随 decision_json 往返，不增加列或 schema 版本。字段缺失表示没有记录证据，空列表表示确实未选 State；清空 model_request_log 不删除该业务快照。完整 State 事实与图片仍属于可删除日志。

AssistantRecord.coordination 是实际请求携带的可选来源证据，包含采集时间、是否打断了此前回复的 interrupt 布尔结果（nil 表示没有有效决策；旧记录的字符串 decision 读取时映射为布尔值，写入只用 interrupt）、决策路径及批次成员ID；批次完整输入保留各成员来源/时间/打断结果，不为成员单独建行。单条原文上限16 KiB。重启仅将已发出的生成中请求标记 interrupted，不重放效果。

每次请求的完整业务文本保存于 user_input_json.requestText（首次请求和 ReACT 均在实际发起时写入），text 继续保存对应原始输入/观察，coordination 保存来源与批次。后续 checkpoint 保留 requestText；详情、窗口、分页预览和导出按本次 requestText 读取，不以原始主输入覆盖。清理完整调试日志不删除 requestText 或回复正文。旧多成员批次的完整详情仅在尚存日志包含相同成员ID集合时恢复实际批次文本；没有相应日志时保留既有原文，不重建或猜测。

准备中的模型请求标记 awaitingDispatch；checkpoint 跳过未发出的请求与没有已发请求的输入，模型发送回调才清除标记并在同一事务保存输入/请求。传输失败仍更新原请求行；预览仅返回持有 invocation 的记录。版本不同的旧库按 [Database](../README.md) 规则重建。

模型生成结束的 checkpoint 更新已发请求的回复、生成终态及生成证据；Action journal 由执行轮次结算补写到原行。全双工 `state.clear("task")` 用同一历史写入边界确认已发请求、封存已关联的来源并提交任务摘要。已发请求继续更新原行，尚未发出的旧任务请求不能在结束后新建来源行。

AssistantInputCoordination 的可选 members 保存实际发起批次的成员 ID、来源、采集时间、分类及路径，沿用现有 coordination JSON。请求正文保存发送时的自然文本时间线，来源行只显示秒级本地时间。旧请求的原始证据保留，回放投影由 Agent 拥有。

模型身份在标记实际发出的同一写入中保存，首轮及 ReACT 各自携带自己的模型身份和可用的执行信息。模型传输证据随完整日志清理，业务正文保留。

打断后的回复结算按已发请求 ID 写入。Storage 校验 UTF-8 片段范围，按提交顺序拼接，重复片段只保留一次。`assistant_response_json` 在正文旁保存 `replyTruncation`（轮次及完成的 Action ID）和 `generatedResponse`（原始生成文本）。重复写入同一结果可重试，冲突结果拒绝。旧标记仍可读取，工具配对和 Action journal 保留原有记录。
