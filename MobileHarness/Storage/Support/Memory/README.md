# Bounded Process Memory

## Responsibility and implementation

File/document memory fixtures belong to Files. BoundedMemoryStream and MemoryLeaseStore retain existing byte/item/owner/finish/failure contracts. StorageOperationGate admits one operation plus16 FIFO waiters by default; configurable0–1024 waiters reject invalid configuration.

## Direct relationships

Compiled in StorageCore; Foundation/Synchronization only. Audio and media/chat services use these generic mechanisms; business record schemas/policies stay in their domains.

## Lifecycle and failure contracts

Document values default64KiB and failed/stale writes preserve the snapshot. Binary defaults256 objects/64MiB, four listing cursors and128-item pages; non-overwrite/traversal/size failures preserve bytes. Ordinary gate cancellation before its body releases admission; captured checkpoint bodies have a joined store-owned lifetime independent of caller cancellation. Cancellation within other bodies follows their actual operation contract. Stream finish drains, failure clears/wakes; leases validate exact owners and join cancellation. Operation/reader/timer tokens use UUID.

[Parent](../README.md)

Cancellation completion: ordinary gate callers reject cancellation before their body; captured Chat checkpoints instead run a joined, store-owned operation independent of the cancelled caller, so cancelled/failed messages still commit. An actual cancelled-Task terminal checkpoint regression verifies received text and both terminal message states.

Registered state now belongs to [State](../../State/README.md); StateWriter atomically retains a typed public fact and its bounded encoded projection. Private AgentContext memory remains inside Agents.

## 待实现

- Registered transitions/subscriptions are implemented in StorageState; durable streams remain outstanding.


✅ MemoryLeaseStore 的移除回调使用明确 released/failure 原因。正常 release 仍留下 missing tombstone、关闭旧值并加入生产者取消；真实 fail/过期保留原错误，二者不再依靠同一个 Error 推断。
