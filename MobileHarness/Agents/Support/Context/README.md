# Agent Runtime Context and Task State

## Responsibility and direct relationships

✅ AgentContextRepository compiles in Agents and adapts AgentCore state to Storage StateRepository/MemoryStateStore. AgentTaskSkillState owns Skill/task transitions; AgentFixedTaskCoordinator joins fixed-task results. Roles own schemas, admission, classification and retention. SQLite writes belong to injected Chat/Task repositories, not this directory.

## Runtime state ownership

Every production role has one root-owned repository backed by a single typed MemoryStateStore snapshot. The store uses a Mutex and no Codable encoding, file, database or hidden flush. Returned values are snapshots; stable business IDs express references across owners. Actor transactions serialize at most16 FIFO waiters; overflow rejects. Copy, mutate, advance revision and validate before publishing the new value. No suspended model/device operation holds the slot.

recordSignal encodes bounded neutral evidence into Data retained in memory, not a JSON file. Caller-selected rolling retention is4096 for deterministic role evidence/batches; unconfigured Core limits remain8192 with explicit rejection. Logical evidence Data totals at most32MiB; overflow rejects before publication without encoding the whole snapshot. Media bytes and credentials are excluded. Signal/delta updates never cause whole-context serialization or I/O.

Generic injected load/commit hooks support atomicity/failure fixtures and preserve the previous value on commit failure; production installs no such hook. The stored/document factory and ContextDocumentAdapter are removed, including File Context fixtures. Durable restart tests use SQLite; fresh runtime repositories do not replay prior work.

## Task and Skill lifecycle

A pure Skill transition receives an already committed Task ID. The Chat worker validates a candidate, inserts running in SQLite, binds memory, and explicitly closes a failed binding. Temporary Skills, Task registries/views, queues and awaiting-feedback stages remain memory-only. Finish/cancel/failure waits for actual execution barriers, then persists terminal state/summary and sources through normalized repositories.

Task entry preserves ordinary background context and complete current-task evidence. Only terminal Tasks compress their process at the first source position; sources remain queryable. finishTask ends the decision unless continueDecision=true explicitly authorizes another objective; cancelTask ends it. Camera/media access does not require a Task authorization record.

## Crash, cancellation and failures

Restart discards hot state; App closes unfinished SQL identities as interrupted and never replays actions. Task compression comes from SQL source relationships, not a serialized Skill/registry snapshot. Cancellation cleanup is joined by the owner; failed persistence retains the terminal checkpoint and blocks subsequent model admission. Repository waiters release their granted slot even after cancellation. Snapshot/state/capacity/commit failures propagate without fallback.

✅ Runtime shared state, bounded admission, independent terminal persistence and structured Task/Skill control are implemented.

❌ Durable live-worker resumption, cross-process runtime sharing and general state subscriptions are not implemented.

[Agents](../../README.md) · [Chat](../Chat/README.md) · [Storage](../../../Storage/README.md)
