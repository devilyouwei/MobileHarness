# SQLite Infrastructure

## Responsibility and implementation

SQLiteDatabase is internal to StorageSQLite and owns DatabasePool, configuration, bounded write admission, migration execution, transaction dispatch and temporary-test-file cleanup. It accepts SQL migrations from domain adapters and contains no business schema/query.

## Direct relationships

StorageSQLite links GRDB.swift7.11.1 and Storage. App creates SQLiteRepositories; the domain adapters share this one pool/runtime namespace. GRDB/SQL types never appear in public repository contracts.

## Lifecycle and failure contracts

WAL, foreign keys, synchronous FULL, four readers; one writer/16 waiters, overflow busy, native SQLite busy timeout2s. Transactions are synchronous and cannot span model/file awaits. Committed-row diagnostics and exact query plans are backend-test capabilities, not generic interfaces. Temporary files are removed only after successful pool close.

[Parent](../README.md)

accept named domain-supplied migrations, including partial unfinished-message and unfinished-Task indexes. Generic database support owns pool/transactions only; ORM records and lifecycle SQL remain with the domains.

## 待实现

- Alternate database libraries/backends and cross-process application ownership are not implemented.
