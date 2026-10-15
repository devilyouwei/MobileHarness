# Registration, Context and Coordination Mechanisms

## Summary

Bounded lifecycle registration, generic decision context, input admission and task/round coordination.

## Ownership and boundaries

AgentManager owns live identity and grants; concrete roles own workers and lifecycle behavior. This independent runtime framework directory has no role/model/Storage implementation. Repository implementations and persistent stores live outside this Foundation-only directory.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Host[App lifecycle] --> Manager[AgentManager]
 Manager --> Registry[AgentRegistry]
 Registry --> Role[Agent instance]
 Role --> Gate[AgentAdmissionGate and SignalInbox]
 Role --> Context[AgentContext and immutable decision snapshot]
 Role --> Round[RoundCoordinator and TaskBudget]
 Manager --> Grants[Scoped task and execution grants]
```

## Identity and lifecycle

Registry permits 64 Agents and rejects duplicates/full capacity. Registration issues an incarnation ID and optional session binding. Stop revokes identity/task grants before joining Agent work and resource cleanup; repeat stop joins the same cleanup. Up to four stop observers are supported. A stopped instance is terminal; replacement requires a new instance after removal. Pause semantics belong to each role.

Manager retains at most 32 active task grants and 32 execution scopes per task, validating both participant incarnations and full scope. Stop revokes descendants and joins cleanup. ActionResultInbox retains 128 terminal results by default (configurable 1–512), deduplicates execution IDs and counts history eviction; it is not a work queue.

## Context and round state

AgentContext<State> version 1 validates agent/scope/revision, at most 8192 records (each ≤512 KiB), 8192 consumption batches and 256 work/task records. Active work cannot be evicted/erased. append/consume may explicitly retain a recent window with counted eviction; default overflow rejects. Restart recovery interrupts unfinished work without replay.

AgentDecisionContext validates immutable snapshots and selected Signal/batch membership. AgentRoundCoordinator registers up to 120 calls, deduplicates results, seals/cancels and gates result-driven reasoning continuation. AgentTaskBudget records cumulative usage for one input across continuations, with nil production request/native limits and representation-safe saturation; positive explicit limits are enforced. A later user input has a fresh Decision budget, even within the same foreground Task. Persistence contracts contain no Storage dependency.

## Admission and cancellation

SignalInbox accepts capacities 1–8192, takes highest priority first and FIFO within a priority, and fuses at most 128 same-key inputs within one session/task. Only explicit replaceLatest removes pending same-key entries; replacement itself is keyed across the inbox, so the role owns key scoping. New entries at capacity reject. The inbox does not apply an implicit queue TTL; explicit input validation and lifetime remain role-owned.

AgentAdmissionGate serializes short actor state/commit sections across suspension. A lock protects its permit and bounded FIFO waiters. Overflow rejects; cancellation removes a waiter; close fails queued waiters. The role releases on every exit and checks cancellation before processing. Model/device work must not retain the permit.

Bounded registration, revocable grants and generic context/admission/round mechanisms are implemented.

## Related design

[Parent design](../README.md)

## Round results and memory

AgentRoundCoordinator registers call IDs, accepts actual ToolResult values and computes needsReasoning only after every call completes and the round seals. Explicit business values or real failure permit continuation; pure cancellation does not. Registration contains no injected feedback policy. Evidence payloads have a 32 MiB logical Data bound independent of filesystem encoding; owner/count limits and explicit overflow remain.

## Processing work state

```mermaid
stateDiagram-v2
 [*] --> queued
 queued --> running
 running --> awaitingFeedback
 awaitingFeedback --> continuation
 continuation --> running
 running --> completed
 running --> failed
 queued --> cancelled
 awaitingFeedback --> cancelled
 continuation --> cancelled
 running --> cancelled
 queued --> interrupted
 running --> interrupted
 awaitingFeedback --> interrupted
 continuation --> interrupted
```

这是角色工作流的常见路径，不是 AgentContext 强制的完整转移矩阵。transitionWork 拒绝未知工作和已终态工作；角色选择非终态转移。模型请求、单个调用和业务 Task 的终态独立。上下文容量只允许淘汰终态 work；重启恢复只标记 interrupted，不重放效果。

## 待实现

- Factory creation, automatic restart and generic health supervision are not implemented.
