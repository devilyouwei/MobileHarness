# Writer Workspaces

writer_workspaces 拥有 Workspace 标题、入口、文件索引、草稿、写租约和删除标记。没有委托执行状态或当前请求外键；单活跃执行、等待、终态及通知由 [WriterMessages](../WriterMessages/README.md) 的委托入口拥有。

WorkspaceRepository/SQLiteWorkspaceRepository 与 WorkspaceStore 协作管理文件。workspace_token 为提交 fence，write_lease 排他写入，has_draft 与 index_needs_recovery 分别表示草稿和索引修复。文件是权威，重启只核对索引、不重放模型操作。跨文件与 SQL 失败显式传播。

接收委托不创建 workspace。显式 create 分配 workspace 并创建空目录后绑定。enter 和 open 绑定已就绪 workspace。WriterExecutionRepository 在同一事务校验入口仍运行且没有不同目标，不搬移消息。名称从 workspace 元数据读取，不被新委托目标覆盖。

删除要求没有活跃委托绑定和写租约；文件清理后保留 deleted 行及消息关联，目录查询不返回已删除项。历史页面可以继续显示其证据，文件读取明确不可用。SQL-free 文件协作编入 StorageDatabase，值/接口编入 StorageTasks，SQL 实现编入 StorageSQLite；[Database](../README.md) 负责连接与装配。

作品库搜索在 SQLite 内对就绪记录按标题、描述或精确任务身份匹配。每页最多十二项，按降序 ID 返回元数据和继续游标。搜索无需读取文件内容或完整目录。
