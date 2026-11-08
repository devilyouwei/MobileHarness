# Shared database mechanisms

本目录只保存无 Agent 业务语义的机制：SQLiteRecordCoding 负责 JSON 编码/解码、消息编号分配和地址解析；SQLiteRecordKey 负责稳定 ID/trace 编码；HistoryPaging 定义有界分页大小。这里没有会话、任务、历史窗口、业务 DTO 或跨 Agent 仓库路由。

Assistant 和 Writer 的消息写入、查询、窗口与记录转换分别归属各自消息表目录。共享业务表的接口和实现也跟随表：[ModelRequestLog](../ModelRequestLog/README.md) 保存模型协议日志；[AgentMessages](../AgentMessages/README.md) 保存 Agent 间通信。数据库连接、schema 装配与生命周期见[Database](../README.md)。

编码错误、非法地址与编号耗尽显式失败。工具只借用调用方事务，不持有连接、不决定任务归属、不启动独立提交。
