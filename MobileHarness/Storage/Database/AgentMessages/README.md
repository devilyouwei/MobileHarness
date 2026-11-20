# Agent messages

agent_messages 记录不可变通信信封及投递事实，不包含 task、workspace、goal 或任务状态列。payload_json 是实际消息正文。id 为 UUID，sender/receiver/dedupe_key 联合唯一，重复键身份或正文不同报冲突；payload 最大 128 KiB。

received 与 consumed 均不代表任务完成。拒绝是接收方反向消息，发送失败记录投递错误。消息拒绝和任务完成都以 agent.task.events.v1 写入 outbox；发布领取 token 防迟到回调，最多八次准入失败退避重试、源端通知单条领取，退休查询每批至多三十二条，耗尽进入 dead_letter。权限退休由 Writer 管理，不能用消息送达代替。关系与共享端口见[Database](../README.md)。

## Interfaces

AgentMessageRepository/SQLiteAgentMessageRepository 是独立通信端口，不继承或实现任一 Agent 的任务接口。OutputGateway 和两个 Agent 显式注入此端口；幂等入队及消费更新可借用当前业务事务。

接收方可在消费前将消息关联到同一来源和接收方的现有通信。关联只更新 reply_to 和 correlation，正文与身份保持固定。消息级拒绝原子消费原消息，并保存按原消息关联的 agent.task.events.v1。

## Signal evidence and task cursors

source_session_id records the authenticated submitting session; legacy absence remains unknown. task_observation_cursors stores receiver-scoped monotonic row positions, capped at 256 per receiver. taskEvents pages at most 64 matching task events and supports explicit replay offsets. receiveAgentMessage(consumed:true) advances only through a contiguous consumed prefix in the same transaction, never past an earlier unconsumed event. consumeTaskEvents consumes the event at the acknowledged position and advances the cursor only through the contiguous consumed prefix, in one transaction.

invocation_evidence stores immutable Data keyed by UUID and owner context, bounded to 4 MiB plus encoding overhead per entry. Conflicting reuse fails. Invocation snapshots reference this archive instead of enlarging agent_messages payloads. Evidence persists for historical replay; no automatic age eviction is applied. New task events use agent.task.events.v1; reads and pending-delivery scheduling explicitly include legacy agent.task.response/writer.completion without rewriting historical payloads.

Publication and consumption are separate facts. published_at records source-side Gateway admission; received_at/consumed_at and task cursors record consumer acknowledgment. A consumer acknowledgment of a task event leaves publication delivery_state unchanged. observationRequests pages at most 64 unresolved root requests for the calling sender, accepting the supported historical request names, without running Agent logic. The consumer owns subscriptions and recovery.
