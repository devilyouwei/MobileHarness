# Agent Runtime Context and Task State

✅ 已实现：热状态升级为 v4，移除 temporaryInputID，分别保存 Task 根 Skill、会话根 Skill 的 remainingDecisions/最近使用顺序/最后使用会话和最多 32 个在途 Decision 使用集合。基础常驻；Task 持有项在终态回收，不转近期；无 Task 合法调用/显式加载续期为 5，整条用户 Decision 未使用扣 1，到零回收。Task 期间暂停未持有会话项倒计数。按展开后非基础总数 3、正文/增量函数目录 24 KiB 淘汰非保护 LRU；已在途 Decision 用过的项受保护。回收事件记录 idle/capacity/taskEnded/explicit/conversationClosed/sessionClosed 原因；定义缓存保留不意味着模型激活。共享依赖保留引用；所有加载验证/回收原子提交，失败不改变旧状态。新对话和重启清理全部会话保留；定向会话关闭只清理属于该会话的近期项，不影响其他会话。Task 收尾与用户 Decision 结算分离，防止 finishTask 屏障及最终收尾重复扣数。

## Responsibility and direct relationships

✅ AgentContextRepository compiles in Agents and adapts AgentCore state to Storage StateRepository/MemoryStateStore. AgentTaskSkillState owns Skill/task transitions; AgentFixedTaskCoordinator joins fixed-task results. Roles own schemas, admission, classification and retention. SQLite writes belong to injected Chat/Task repositories, not this directory.

## Runtime state ownership

Every production role has one root-owned repository backed by a single typed MemoryStateStore snapshot. The store uses a Mutex and no Codable encoding, file, database or hidden flush. Returned values are snapshots; stable business IDs express references across owners. Actor transactions serialize at most16 FIFO waiters; overflow rejects. Copy, mutate, advance revision and validate before publishing the new value. No suspended model/device operation holds the slot.

recordSignal encodes bounded neutral evidence into Data retained in memory, not a JSON file. Caller-selected rolling retention is4096 for deterministic role evidence/batches; unconfigured Core limits remain8192 with explicit rejection. Logical evidence Data totals at most32MiB; overflow rejects before publication without encoding the whole snapshot. Media bytes and credentials are excluded. Signal/delta updates never cause whole-context serialization or I/O.

Generic injected load/commit hooks support atomicity/failure fixtures and preserve the previous value on commit failure; production installs no such hook. The stored/document factory and ContextDocumentAdapter are removed, including File Context fixtures. Durable restart tests use SQLite; fresh runtime repositories do not replay prior work.

## Task and Skill lifecycle

A pure Skill transition receives an already committed Task ID. The Chat worker validates a candidate, inserts running in SQLite, binds memory, and explicitly closes a failed binding. Recent Skill counters/Decision-use sets, Task registries/views, queues and awaiting-feedback stages remain memory-only. Finish/cancel/failure waits for actual execution barriers, then persists terminal state/summary and sources through normalized repositories.

Task entry preserves ordinary background context and complete current-task evidence. Only terminal Tasks compress their process at the first source position; sources remain queryable. finishTask ends the decision unless continueDecision=true explicitly authorizes another objective; cancelTask ends it. Camera/media access does not require a Task authorization record.

## Crash, cancellation and failures

Restart discards hot state; App closes unfinished SQL identities as interrupted and never replays actions. Task compression comes from SQL source relationships, not a serialized Skill/registry snapshot. Cancellation cleanup is joined by the owner; failed persistence retains the terminal checkpoint and blocks subsequent model admission. Repository waiters release their granted slot even after cancellation. Snapshot/state/capacity/commit failures propagate without fallback.

✅ Runtime shared state, bounded admission, independent terminal persistence and structured Task/Skill control are implemented.

❌ Durable live-worker resumption, cross-process runtime sharing and general state subscriptions are not implemented.

[Agents](../../README.md) · [Chat](../Chat/README.md) · [Storage](../../../Storage/README.md)
