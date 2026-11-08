# Assistant conversations

assistant_conversations 保存 Assistant 对话头：整数主键、title、created_at、archived_at、revision。唯一部分索引保证只有一个当前会话。计数和最新输入从本侧消息投影，不持久化重复计数或恢复 blob。标题诊断位于可删除辅助日志。

仓库负责当前会话、分页、归档、删除和标题。活跃前台任务阻止旋转；删除只级联 Assistant 私有消息和任务，不影响 Writer。AssistantConversationRecord 是端口投影，traceID 从主键稳定派生。关系见[Database](../README.md)。

## Interfaces

AssistantConversationRepository/SQLiteAssistantConversationRepository 只管理 Assistant 会话头、归档、标题及辅助标题请求记录。AssistantConversationRecord 不携带 agent 分派字段；Writer 的历史头由 WriterMessages 单独投影。
