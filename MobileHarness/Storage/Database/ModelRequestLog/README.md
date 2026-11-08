# Model request log

model_request_log 独立保存完整 HTTP 应用层请求/响应字节（包含 SSE）、参数、图片、headers、时间和 generation meta。assistant_message_id、writer_message_id、assistant_conversation_id 恰一非空；标题属于辅助会话日志。invocation_id/transport_index 唯一。非 HTTP 调用明确标 local，失败采集标 partial。

ModelKit 提供中立采集回调，Agents 桥接至本仓库；64 KiB 分块背压写入。采集初始化与消息准入一致，后续只 UPDATE；清空日志后迟到回调不重建。清空只删除日志，图片无相册回退，业务文本与工具结果独立保留。凭据 header/URL 参数由传输 adapter 脱敏。关系见[Database](../README.md)。

## Interfaces

ModelRequestLogRepository/SQLiteModelRequestLogRepository 独立拥有协议数据和 generation meta。共享 ModelEvidence 只描述协议值，不引用 Assistant/Writer 私有记录。辅助标题请求的业务入口属于 AssistantConversations；日志更新/清理使用独立日志端口。
