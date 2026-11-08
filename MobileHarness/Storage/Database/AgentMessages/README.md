# Agent messages

agent_messages 记录不可变通信信封及投递事实，不包含 task、workspace、goal 或任务状态列。payload_json 是实际消息正文。id 为 UUID，sender/receiver/dedupe_key 联合唯一，重复键身份或正文不同报冲突；payload 最大 128 KiB。

received 与 consumed 均不代表任务完成。拒绝是接收方反向消息，发送失败记录投递错误。完成通知由 Writer 本地终态事务写入 outbox；投递领取 token 防迟到回调，最多八次退避重试、用户通知单条领取，退休查询每批至多三十二条，耗尽进入 dead_letter。权限退休由 Writer 管理，不能用消息送达代替。关系与共享端口见[Database](../README.md)。

## Interfaces

AgentMessageRepository/SQLiteAgentMessageRepository 是独立通信端口，不继承或实现任一 Agent 的任务接口。OutputGateway 和两个 Agent 显式注入此端口；幂等入队及消费更新可借用当前业务事务。
