# Bounded Process Memory

## Responsibility and implementation

File/document memory fixtures belong to Files. BoundedMemoryStream and MemoryLeaseStore retain existing byte/item/owner/finish/failure contracts. StorageOperationGate admits one operation plus16 FIFO waiters by default; configurable0–1024 waiters reject invalid configuration.

## Direct relationships

Compiled in StorageCore; Foundation/Synchronization only. Audio and media/chat services use these generic mechanisms; business record schemas/policies stay in their domains.

## Lifecycle and failure contracts

Document values default64KiB and failed/stale writes preserve the snapshot. Binary defaults256 objects/64MiB, four listing cursors and128-item pages; non-overwrite/traversal/size failures preserve bytes. Ordinary gate cancellation before its body releases admission; captured checkpoint bodies have a joined store-owned lifetime independent of caller cancellation. Cancellation within other bodies follows their actual operation contract. Stream finish drains, failure clears/wakes; leases validate exact owners and join cancellation. Operation/reader/timer tokens use UUID.

[Parent](../README.md)

Cancellation completion: ordinary gate callers reject cancellation before their body; captured Chat checkpoints instead run a joined, store-owned operation independent of the cancelled caller, so cancelled/failed messages still commit. An actual cancelled-Task terminal checkpoint regression verifies received text and both terminal message states.

Registered state now belongs to [State](../../State/README.md); StateWriter retains the authoritative in-memory value without JSON encoding. Agent owners enforce value limits and domain transactions.

## 待实现

- Registered transitions/subscriptions are implemented in StorageState; durable streams remain outstanding.
