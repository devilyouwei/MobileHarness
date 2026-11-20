# Agent messages

agent_messages 记录不可变通信信封及接收事实，仅供追踪，并在 UI 设置的记录页展示；业务逻辑不读取它来决定是否处理消息。表中不包含 task、workspace、goal 或任务状态列。列为 id、sender_agent_id、receiver_agent_id、contract、schema_version、payload_json、correlation_id、reply_to_id、sender_context、source_session_id、dedupe_key、created_at、received_at、consumed_at，索引 agent_message_receiver(receiver_agent_id, created_at)。payload_json 是实际消息正文。id 为 UUID，sender/receiver/dedupe_key 联合唯一，重复键身份或正文不同报冲突；payload 最大 128 KiB。

received 与 consumed 均不代表任务完成。Agent 之间的发布只发送一次，本表不承担投递、重试或补发。权限退休由 Writer 管理，不能用消息送达代替。关系与共享端口见[Database](../README.md)。

## Interfaces

AgentMessageRepository/SQLiteAgentMessageRepository 是独立通信端口，不继承或实现任一 Agent 的任务接口。接口为 archiveInvocationEvidence、invocationEvidence、enqueueAgentMessage、agentMessage、isAgentMessageConsumed、associateAgentMessage 和 receiveAgentMessage。OutputGateway 和两个 Agent 显式注入此端口；幂等入队及消费更新可借用当前业务事务。

接收方可在消费前将消息关联到同一来源和接收方的现有通信。关联只更新 reply_to 和 correlation，正文与身份保持固定。Writer 拒绝消息时以 receiveAgentMessage(consumed:true) 消费自己收到的请求记录；拒绝回报本身不由 Writer 写入本表。Assistant 收到 Writer 回报后以 enqueueAgentMessage 加 receiveAgentMessage(consumed:true) 写入追踪记录。

## Signal evidence

source_session_id records the authenticated submitting session; legacy absence remains unknown.

invocation_evidence stores immutable Data keyed by UUID and owner context, bounded to 4 MiB plus encoding overhead per entry. Conflicting reuse fails. Invocation snapshots reference this archive instead of enlarging agent_messages payloads. Evidence persists for historical replay; no automatic age eviction is applied. New task events use agent.task.events.v1.

received_at/consumed_at record the receiver's own trace of a message. The consuming Agent owns subscriptions; this repository provides no publication state, pending-delivery scheduling or recovery reads.
