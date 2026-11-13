# Writer messages

writer_messages 仅保存实际发起的模型请求；writer_executions 独立保存委托生命周期，入口保存原始输入、request_goal、run_state、terminal_state、request_revision、pending_question_id、pending_question_json、result_json 和 failure_json；user_input_json 同时保存原始输入、来源 Agent/会话及原始通信包；关联不可变 agent_messages 来源。每个通信请求只能有一个入口，单活跃索引覆盖运行、等待、暂停及清理。

模型请求用 delegation_id 指向 writer_executions 入口，workspace_id 为创建当时的 workspace 或空值。入口的 selected_workspace_id 记录执行目标，对外投影为 workspace_N；选择不修改旧消息，前序和进入后的消息都属于同一委托。position 固定为事务分配的全局消息主键；revision 只作状态版本。模型调用状态与入口 run_state 独立。

tool_catalog_json 只保存本轮 decisionMetadata.catalogJSON.tools 的目录条目数组，包含工具别名、路径、参数名和 definitionJSON。输入 checkpoint 不写工具目录；查询通过同一请求的 decisionMetadata 还原，不转换为字符串数组，也不借用输入根或其他轮次目录。工具定义不存在第二份 WriterRecord 字段或保存接口，清理日志保留目录。

WriterInputMessage 保存当前轮 user/tool 文本及工具名/关联 ID，存入 user_input_json.messages，不携带图片或完整历史上下文。查询独立于日志恢复 inputMessages；checkpoint 更新输入摘要时保留已有 messages。输入快照计入 WriterHistoryStore 的窗口容量，清日志后不变。

WriterExecutionRepository/SQLiteWriterExecutionRepository 同属本目录，负责入口接纳、目标绑定、补充输入、请求状态和完成 outbox。终态与 outbox 原子提交到执行入口，不插入虚构模型消息。补充输入仅消费已有 agent_messages，不复制为 writer_messages。完成投递和权限退休独立，重试仍有界。重复通信幂等；恢复标记 interrupted，不重放工具。

WriterMessageRepository/SQLiteWriterMessageRepository、WriterRecordStore、WriterHistoryStore 与 WriterRecords 构成消息链。运行窗口按委托读取；workspace 查询是另一过滤范围，前序查询额外限制 workspace_id IS NULL。HistoryStore 的 bindingWorkspace 在串行写门内 checkpoint 后执行绑定，不切换窗口或移动消息。新委托切换前必须没有未提交/生成中的输入，写入等待最多 16，满时 busy。

日志由 ModelRequestLogRepository 独立拥有。清理日志保留输入、工具目录、结果、所属委托和 workspace；后续回调不重建清除的日志。

WriterContainer 将本侧历史映射到 UI 详情/导出展示模型；展示格式不成为跨 Agent 的存储接口。关系见[Database](../README.md)。

详情序号按消息自身所属 workspace（前序消息按该委托的前序范围）计算；工具来源仍在同一委托完整链中查询，只为严格较早且唯一匹配的 providerID 返回来源请求地址。所选调用的 model、maximumOutputTokens 和 temperature 从 generation_meta_json 投影为可选值。宿主收尾记录以所属模型调用 ID 写入 runtime_results_json，保留已有的委托完成标记；找不到调用时明确报错。清空日志保留工具来源关系与宿主收尾。

WriterHistoryStore.requestPreviews 透传有界 limit（默认 20，仓库上限 50），供调用方做轻量记录前瞻。工作区消息页按 position 降序，使用排他的 before 游标读取更早一页，轮次编号仍按正序计数。按 after 查询用于近期消息更新、前序历史及导出。Storage 返回查询事实，不决定 UI 页大小或末页显示；WriterContainer 拥有公开分页结果。

Writer 从普通消息正文识别明确停止请求后，在同一事务确认来源及执行身份、标记原消息已消费、进入 closing 并保存原因。清理结果由 Writer 随独立终态通知提交。私有模型选择取消时，终态事务保存它的事实摘要。既有取消记录可按历史消息读取。

新入口接纳 agent.task.request，消息身份成为执行入口的来源。Writer 判定为补充或停止后将消息关联到原入口，存储核对来源、关联身份和当前执行状态后消费。消息级拒绝留在 Agent 消息表，与任务终态共用 agent.task.response 的持久投递；退休查询只选择任务终态。旧 writer.completion 数据仍可读取，待投递记录以当前契约发出。

忙碌拒绝使用 rejected 入口并记录失败原因与完成时间，计入委托列表但不参与运行上下文选择。委托终态结果由入口 result_json 保存，通知删除或日志清理不改变业务结果。

Writer 控制请求将作品库、编辑或查看域写入 producerMetadata.controlDomain。进入工具所在消息保留前序归属，进入后的请求携带 workspace_id。恢复按委托与控制域选择消息，查询结果和跨域操作仍可审计。

运行中切换工作区要求委托当前绑定与预期旧目标一致。SQLite 在同一事务中确认新工作区可绑定并更新委托选择，已有消息的 workspace_id 和请求身份保留。新建后切换先分配目标，当前绑定在目标准备成功后更新。

WriterHistory.begin 准备内存请求，awaitingDispatch 在 HTTP 发送或本地推理开始时清除；仅此时原子创建消息与输入快照。配置失败或发起前取消没有 message，真实网络失败保留请求身份、输入与失败信息。每次真实重试独立记录；workspace 绑定取实际创建消息时的执行目标。
