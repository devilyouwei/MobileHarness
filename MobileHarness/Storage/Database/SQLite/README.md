# SQLite implementation

SQLiteDatabase owns the GRDB pool, bounded admission, transactions, current-schema preparation and
joined shutdown. Domain adapters own SQL and private row mappings. AppStorage selects the backend;
business consumers receive contracts and never import StorageSQLite. WAL, foreign keys and FULL
synchronization are enabled; four readers, one writer plus sixteen write waiters, two-second SQLite
busy timeout and sixty-four admitted operations. Overflow is an explicit error.

## Schema and recovery

The ten domain tables and their relationships are documented in [Database](../README.md). No migration,
legacy decoder, evidence/chunk table, task-message join table, workspace version table or independent
notification table exists. Unknown development user_version is erased and rebuilt in one transaction.
SQLite's own sequence table allocates non-reused readable numbers; a namespaced internal sequence
entry retains each delegated owner's counter even after all its tasks are deleted.

SQLiteChatRepository persists rounds and request logs with JSON TEXT. It projects roles for existing
history consumers without storing separate role rows. Request addresses use request_N; input round
addresses use message_N. Metadata-only pages avoid loading request/source contexts. Raw round pages
carry an explicit continuation cursor, so nested requests cannot truncate a page. Generating records
recover as interrupted, and foreground interruption summaries preserve original source associations.

SQLiteTaskRepository atomically admits Writer-owned tasks and UUID delegations. Current-delegation
checks fence phase updates; completion and immutable terminal payload commit together in
agent_delegations. Delivery and permission retirement are independent receipts on that row, not a
second queue table. Assistant source deletion clears nullable references without cascading Writer data.

SQLiteWorkspaceRepository stores current metadata in writer_tasks and path/size/fingerprint rows in
workspace_files. A durable write lease excludes concurrent writers; startup clears abandoned leases
and marks their workspaces dirty. It stores no code. Deletion rejects active delegations and retains a
marker through filesystem cleanup. The Workspaces coordinator performs actual file I/O.

Media SQL stores both images and movies and their album inclusion. Native asset validation belongs to
consumers. message_media foreign keys retain resource references; deleting a conversation does not
delete album resources. Device SQL owns native identity and selection. Backend errors flow through
StorageFailureReporter and the original throwing API; no SQL/credential dumps or automatic retries.

In-flight Assistant requests resolve their UUID before round placement. startTask may atomically
attach an unassigned request to a foreground-task segment, preserving the request key and earlier
requests while refreshing both segment aggregates. Rebinding an established task or changing input
ownership fails. Delegation-status reads do not require an accepted workspace; missing identities and
requested rows are ordinary lookup results, distinct from SQL failures.
