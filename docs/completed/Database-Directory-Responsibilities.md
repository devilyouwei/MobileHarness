# Database directory responsibilities

2026-11-07. Scope: follow up the completed independent-Agent schema with table-owned operations and narrow interfaces. No table/column/schema-version change, data reset, device installation or new compiled module is required. Preserve the existing working tree and the previous implementation.

## Intended ownership and files

- Database root retains SQLiteDatabase, SQLiteSchema, DatabaseStorage/SQLiteDatabaseStorage/SQLiteRepositories: connection, transactions, lifecycle and assembly. Shared owns aggregate Chat/Task contracts and facades; they only route or coordinate transactions and recovery, delegating table-specific SQL to table owners.
- AssistantTasks owns the foreground-task contract and its recovery/summary invalidation. WriterTasks owns Writer request/task contracts and recovery. AgentMessages owns the communication contract; OutputGateway accepts only that contract. Assistant Chat worker accepts foreground-task plus communication ports, without Writer-private operations.
- Split ChatRepository into table/capability contracts for conversation metadata, message access, summaries and request logs. Keep a small aggregate interface for assembly and history transactions, preserving atomic cross-table save behavior. Default fixture behavior and async witness dispatch must remain explicit.
- Shared history window/checkpoint/conversion types and reusable SQL message mechanisms leave the root. The user explicitly approved Database/Shared; it owns common capability mechanisms and their shared contracts. Role-specific message association, summary changes, Writer completion markers, decision projection and preview scope SQL remain in AssistantMessages/WriterMessages or their task owners, rather than accumulating in Shared.
- ModelRequestLog owns generation metadata queries/updates and generation-field classification. No separate SQLite directory remains; core mechanics are directly at Database root.
- Package.swift explicitly retains existing StorageChat/StorageTasks/StorageSQLite target membership. Update source paths and boundary checks, affected directory READMEs, Storage/Agents relationships and overall design. Remove old file paths and implementations without aliases or duplicate code.

## Validation

Use existing SQLite round/summary/history/communication/outbox/workspace tests to verify behavior and rollback. Add focused coverage where new interface separation needs a compile/runtime contract test; do not duplicate moved implementations. Run ./scripts/check.sh and ./scripts/build-ios.sh; avoid concurrent builds during timing-sensitive full tests. Verify formatting, documentation links, per-source compiled ownership and root/table boundaries. Report native test completion gaps separately from successful script exits.

## SQLite assembly correction

SQLiteSchema knows all ten domain tables and the application schema version, so move it to Database root. SQLiteDatabase keeps pool/admission/transactions/shutdown and receives an initialization closure from SQLiteRepositories; it does not refer to SQLiteSchema or domain table types. Move SQLiteRecordKey out of the core into Shared. Preserve existing version/reset behavior and initialization failure cleanup.

## Final directory clarification

The user explicitly clarified: root = database core/assembly, Shared = shared business, table directory = table-specific business. Move SQLiteDatabase to root and remove the empty SQLite directory. Move aggregate ChatRepository/TaskRepository and SQLiteChatRepository/SQLiteTaskRepository to Shared. SQLiteSchema remains root as whole-database assembly; the core connection receives its initializer rather than referencing domain tables. This replaces the earlier plan to retain a SQLite subdirectory.

## Business API separation (2026-11-08)

The user rejected the aggregate Chat/Task facade and shared Conversation/Dialog domain. This supersedes the aggregate-interface portions above. Remove ChatRepository, TaskRepository, SQLiteChatRepository and SQLiteTaskRepository, without aliases or compatibility adapters. Database assembly exposes Assistant conversations/messages/tasks, Writer messages/tasks, model logs and Agent communications as distinct ports. Private repositories must never select the other Agent's table by an agent argument or inferred ID.

AssistantConversations/AssistantMessages own the Assistant history DTOs, window, checkpoint, projections and persistence. WriterMessages owns its own journal, records and reads; WriterTasks owns task selection/workspace lifecycle. Writer history does not depend on foreground task summaries, conversation rotation, or Assistant repositories. Shared retains only neutral encoding/key mechanisms, not Conversation/Dialog/Task business models or routing. ModelRequestLog owns transport/generation evidence independently; AgentMessages owns communication delivery. Atomic admission/log initialization, task summaries, communication consumption and completion outbox must retain transaction semantics through table-owned internal operations.

Update AgentRepositories, application composition, AgentRuntime, Assistant processing, Writer container/history/notifications and their UI/history adapters to inject explicit ports. Generic chat callers must not gain Writer storage access. Remove role-switching helpers and obsolete files, update Package source membership and boundary checks without adding compiled targets or directories. Update all affected READMEs and validation evidence after implementation. Add regression coverage for cross-role access rejection, standalone log/communication ports and Writer history without Assistant task dependencies. No schema/data reset or device installation is included.

Independent injection also requires explicit storage-scope validation: reject message/task/log/communication ports from different database instances before starting an Agent. The old aggregate object implicitly guaranteed that identity; the new composition must preserve it explicitly. Add cross-scope rejection coverage alongside cross-Agent address isolation.

The full regression run exposed a UI projection assumption: HistoryConversation decoding required Assistant taskCompressions even for Writer details. Update the UI-owned decoder to accept a Writer projection without foreground summaries (empty presentation list); do not add a compatibility field back to Writer storage. Keep required message identity/content decoding strict and retain existing Writer detail round-trip coverage.
