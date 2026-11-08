# Writer 任务与请求详情调整

2026-11-08。Writer 的长期 task 是作品/工作区，页面不再用最近一次执行的状态代表整个任务。

## 实施范围

- UI/Settings/WriterRecordsView 保持任务标题、图标、task ID、文件浏览和执行轮次列表；任务详情依次展示开始时间、更新时间、执行轮数。删除任务级最新状态/失败摘要和持续时间。任务列表同时移除任务状态胶囊。轮次行自己的状态、重试、分页、分组不改。
- 导出任务对话记录改为右上角单个“导出”按钮，沿用现有 shareTask 真实导出/失败/取消流程。
- WriterTaskItem 移除任务级 status/failure/phase 和累计执行时间展示字段；WriterContainer 不再为了页面累计遍历执行记录。数据库/运行时的准入、取消、恢复状态继续归内部执行生命周期所有，不改变任务执行行为。导出仍包含独立 delegations 的真实执行证据。
- 请求详情按 Request Input → 文本 Content/Tool workspace（只展示存在的类型，保留调用参数/结果和失败证据）→ Prompts → Generation Meta 排列。输入直接展开当前最后一组 user/tool 消息；无日志或缺少协议消息时显示已持久化的请求输入，不伪造消息。移除原始完整请求 JSON 展示和旧运行时收尾独立区块；运行时原始证据仍随记录保存/导出。
- WriterHistory 在请求准入时把当前 user/tool 输入保存为 Writer 专属 inputMessages（文本、工具名及关联 ID），落入 writer_messages.user_input_json.messages。图片和完整历史仍仅存日志；清空日志不删除本轮业务输入。Storage 在现有 JSON 列中读写，计入窗口容量；UI 展示 DTO 接收此快照。没有历史快照时仅展示已有输入证据，不伪造。涉及 WriterHistory、WriterRecords、WriterHistoryStore、SQLiteWriterMessagePersistence/Queries 和 UI 展示契约；不新增表或列。
- Prompts 使用与 Assistant 相同的角色列表/折叠消息呈现，保留请求图像及工具定义。完善协议消息的结构化投影，支持应用标准消息、Chat Completions tool_calls/tool_call_id、Responses function_call/function_call_output；缺少日志时不从旧缓存补回。
- Generation Meta 统一位于内容最下方，包含模型、请求时间/ID、参数、结束原因、用量、首 token 与请求耗时。最后放清空日志按钮；清空成功后去掉 Prompts/Meta/按钮，显示 Logs cleared，保留业务输入、回复和工具调用结果。与 Assistant 一样清理内存日志副本，避免二次读取失败误报删除失败。
- 相关文件：UI/Settings/WriterRecordsView、ConversationHistoryPresentation、ConversationHistoryView（共享 Prompts 呈现）、Agents/Writer/WriterContainer；现有 UI 数据测试、Writer 集成测试及原生验收脚本断言。更新 UI/Settings、Writer 与总体 README；无需新增目录或修改表结构。
- 检查：输入/工具配对投影与清空后业务保留测试，./scripts/check.sh、./scripts/build-ios.sh；原生视觉和真机安装结果单独声明。

验证时当前工作树的 Writer library 集成用例向 ActionIdentifier 传入了 String，阻止整个测试目标编译；仅将该用例参数改为现有类型化标识构造，不改变 library 业务实现。

实现与自动化验证完成，证据见[验证记录](../validation/Writer-Record-Detail.md)。原生页面与真机验收限制单列于该记录。


## 真机截图反馈修正（2026-11-08）

复用现有文件，不新增目录或源码文件。原交付/安装和本次修正证据均保留在 validation。

- Assistant 的 Tasks、Skills、States、Function Catalog 放入同一个 Section，每个同级行/内容组保留自己的彩色图标；Functions 使用独立绿色图标。修改 UI/Settings/ConversationHistoryView，保留现有展开及日志删除行为。
- 真机只读核查确认凌晨 01:25–02:37 记录缺少 states，10:29–10:30 新请求已有 states。用户确认新请求有状态；本次不修改 State 记录逻辑、不回填旧数据、不新增列。
- Writer 当前 tool_catalog_json 是目录条目数组，旧查询却尝试读成 [String]，且输入 checkpoint 和 response 分别写入两种格式。统一由每次请求的 decisionMetadata.catalogJSON.tools 写入工具目录；删除 WriterRecord.toolDefinitions、WriterHistoryStore.recordToolDefinitions 及重复读写路径。工具数量/定义字节边界继续由现有 ModelKit.ChatRequest 入口校验（128 项/65536 字节），不重复增加校验。
- Writer Request Input 区块增加默认收起的 Tools 工具集合，显示实际请求工具名称、定义和参数；从本条 request 的业务目录读取，不能从另一轮或当前工具注册表补造。空集合显示 0，缺失与解析失败明确区分。Prompts 不再重复显示该集合。清日志后保留该业务目录。
- Content 输出默认收起，点击后显示完整可复制代码；输入保持直接展开，工具调用参数/结果原交互保留。
- UI 的目录行组件在同一目录内复用；不引入基础模块对 Agent/Storage 的依赖。同步 UI/Settings、Writer、WriterMessages README；更新既有 SQLite、Writer/UI 测试及原生验收断言，运行 check.sh、build-ios.sh，单独报告真机/原生验收范围。

截图反馈修正已完成，专项回归、完整检查和四项 iOS 构建通过；原生页面与修正版真机安装不计为已验收。


## Content 文件条目（2026-11-08）

- Content 按本轮实际文件路径显示可独立展开/收起的文件行，带文件图标且默认收起；不是文件生成的回复继续显示 Text。当前一次文件内容请求对应一个文件，不从其他轮次或实时工作区拼接历史内容。
- Writer 已将目标路径保存到 request.producerMetadata.path，Storage 查询已恢复；UI HistoryModelRequest 增加对应元数据投影，WriterRecordPresentation 读取路径作为折叠项标题。清日志副本保留该业务元数据，保证标题不退回 Text。
- 修改现有 ConversationHistoryState、WriterRecordsView 及既有 UI/Writer 集成/原生验收测试；不新增文件、目录、数据库字段或新的文件存储接口。更新 UI/Settings README，并执行 check.sh、build-ios.sh。原生交互与安装结果单独记录。

Content 文件条目已实现并通过完整检查及四项 iOS 构建，文件名在重开数据库和清日志后保留。
