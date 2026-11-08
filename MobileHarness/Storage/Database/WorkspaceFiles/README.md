# workspace_files

## Ownership and interfaces

The primary key is (task_id,path); task_id cascades with writer_workspaces. Each file row stores bytes (nonnegative), fingerprint and updated_at, never file content or versions.

WorkspaceFileRow.files returns an ordered typed file index. replace deletes the old index and inserts the supplied rows on the caller's Database connection. SQLiteWorkspaceRepository commits this operation together with the writer task's lease/token metadata; a duplicate path/constraint failure rolls back both old-index removal and metadata changes. Disk coordination belongs to [WriterWorkspaces/WorkspaceStore](../WriterWorkspaces/README.md); the table model performs no filesystem I/O and opens no independent transaction.

## Implementation and boundaries

- [WorkspaceFileRow.swift](WorkspaceFileRow.swift)

GRDB records and SQL operations compile in StorageSQLite. Public records and ports compile in their original SQL-free targets; Package.swift assigns each source exactly once. GRDB row types stay internal. Schema/index definitions and explicit CodingKeys live with the record. Repository entry points use the shared database pool; table helpers borrow the caller's transaction and never independently commit, start workers or create another pool. Connection admission, rollback and joined shutdown follow [SQLite](../README.md); see [Database relationships](../README.md) for adjacent table contracts.
