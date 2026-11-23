# Listening dialogs

listening_dialogs 记录 `listening` 处于 `quiet` 时独立退出判定通道的每一次判定，仅供追踪与排查误唤醒、漏唤醒；业务逻辑不读取它来决定是否退出。该表不属于 Assistant 对话，也不保存回复。

列为 id（UUID）、session_id、episode_id、asr_text、decision（`stay`、`exit` 或 `error`）、reason、model_tier（`system` 为 Apple 系统模型，`configured` 为 Assistant 当前选择的模型，`literal` 为本地字面匹配，`model_id=literal-match`）、model_id、latency_ms、error、created_at。索引 listening_dialog_episode(episode_id, created_at) 与 listening_dialog_created(created_at)。episode_id 标识一次不间断的 quiet 停留，进入时生成，同一次停留的所有判定共用；表中没有独立的 episode 行。asr_text 最大 4096 字节。

## Interfaces

ListeningDialogRepository/SQLiteListeningDialogRepository 只追加：appendListeningDialog、listeningDialogs(episodeID:)、recentListeningDialogs(limit:)。保留行数上限为 2000；追加后超限时按创建时间删除最早的整个 episode，正在写入的 episode 不被删除。与其他表无外键。数据库版本不匹配时与其他表一同重建，不做迁移。关系见[Database](../README.md)。
