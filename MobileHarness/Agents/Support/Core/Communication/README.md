# Neutral Communication and Task Contracts

## Summary

Typed immutable messaging, declaration validation, scoped tasks and admission receipts without transport workers.

## Ownership and boundaries

Gateway selects recipients and owns bounded delivery tasks. Agents own inbox/processing/task state. Core defines generic content/rights/catalogs and no concrete speech, pose or device policy.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Agent -->|CommunicationAction| Gateway
 Policy[CommunicationPolicy and Contracts] -->|Authorization and schema| Gateway
 Gateway -->|Directed admission| Receiver[Target Agent]
 Receiver -->|Admission only| Receipt[CommunicationReceipt]
 Receipt --> Agent
 Gateway -->|One-way publication| Subscribers[Exact static / host dynamic subscribers]
```

## Policy and provenance

JSON v6/v7 declares supported inputs, exact contract/source/topic subscriptions, publications and target-specific sends. Supporting a contract is not subscribing. Unknown identities, wildcard/default-Agent fallback and incompatible declarations reject. Catalog capacity is 128; external source allowlist 16; policy bounds 64 Agents/topics and 16 subscriptions/recipients.

AgentMessage captures checked immutable content and encoded size. Schemas declare expected type, validator, byte limit and whether publication starts work. Signals have no default TTL; explicit perception freshness remains producer-owned. Causal metadata preserves incarnation, root/parent/session/turn and at most eight hops. Runtime feedback authority cannot be supplied externally.

## Delivery and task state

CommunicationAction uses the identity-bound output consumer. send selects a live target and returns correlated admission; publish returns Void without receipt/history, even with no subscribers. Publisher validation failures are explicit; subscriber/observer failures are independent diagnostics. No transport FIFO, exactly-once promise, retry or duplicate suppression is provided.

TaskRequest/Input/Progress/Result/Cancel carry scoped business data: at most 65536 bytes of opaque business data and 131072 bytes for the encoded envelope. Only result carries terminal status; requester/executor/session and runtime provenance are validated separately from payload content. AgentTaskRegistry retains 256 records, at most 128 accepted Signal IDs per task and rejects wrong scope, duplicate reports or post-terminal inputs. At capacity only terminal identities can be retired; reports for retired identities reject. Late admission cannot overwrite an earlier true terminal result. Restart interrupts active tasks.

Compatibility AgentMessaging is limited to Gateway/isolated hosts; production roles emit CommunicationAction. Directed receipt history retains 128 entries with counted oldest eviction. SignalTrace snapshots are payload-free passive diagnostics, never publisher acknowledgments.

Strict messaging declarations, scoped task state and distinct admission/terminal contracts are implemented.

## Related design

[Parent design](../README.md)

## 泛化 Task 与独立 Skill

Core provides business-neutral AgentTaskExecution and backward-readable scope.execution, plus bounded goal/requestedSkills evidence. Registry owns admission, delivery and cancellation transitions: 256 records and 16 nonterminal background tasks. Core does not load Skill resources or compose prompts. Missing legacy execution decodes as foreground.

## Lifecycle-owned conversation and audio

Signal 默认没有过期时间；通信授权不附加隐式 TTL。实时感知输入可以声明新鲜度，接收方仍须校验来源、会话和作用域。Task 的终态、显式取消与 owner 清理决定生命周期；请求/调用数和队列容量独立受限。

## 待实现

- Remote serialization and durable delivery are not implemented.

## 动态订阅边界

✅ Gateway 在不可变 CommunicationPolicy 的 schema/来源权限之上增加宿主控制的有界动态订阅；Core 不拥有运行时订阅表，动态关系不得扩展目标输入或发布者权限。
