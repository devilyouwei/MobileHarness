# SQLite Infrastructure

## Responsibility and implementation

SQLiteDatabase is internal to StorageSQLite and owns DatabasePool, configuration, bounded write admission, current-schema preparation, transaction dispatch and temporary-test-file cleanup. It accepts the current SQL schema from domain adapters and contains no business schema/query.

## Direct relationships

StorageSQLite links GRDB.swift7.11.1 and Storage. App selects SQLiteDatabaseFactory; SQLiteDatabaseStorage creates and owns SQLiteRepositories; the domain adapters share this one pool/runtime namespace. GRDB/SQL types never appear in public repository contracts.

## Lifecycle and failure contracts

WAL, foreign keys, synchronous FULL, four readers; one writer/16 waiters, overflow busy, native SQLite busy timeout2s. Transactions are synchronous and cannot span model/file awaits. Committed-row diagnostics and exact query plans are backend-test capabilities, not generic interfaces. Temporary files are removed only after successful pool close.

[Parent](../README.md)

Current domain schemas include partial unfinished-message and unfinished-Task indexes. Generic database support owns pool/transactions only; ORM records and lifecycle SQL remain with the domains.

✅ 共享读写生命周期门最多接纳 64 个操作，写入仍最多 17 个；溢出 busy。beginClosing 同步拒绝新操作；shutdown 合并一个后台任务，加入在途操作后关闭池，失败原样返回且不重开。初始化失败同步关闭未暴露的池，保留初始化与关闭错误。临时文件仅在关闭成功后删除。

## 待实现

- Alternate database libraries/backends and cross-process application ownership are not implemented.

## Storage 容器关系

✅ 本目录的领域端口由 DatabaseStorage 发布；SQL 适配器统一归 Database/SQLite 编译，业务调用方不导入 SQLite 后端。

## 统一容器异常通道

✅ SQLiteDatabaseFactory/Storage/Repositories 把报告器传到 SQLiteDatabase；中央读写、准备、关闭异常原样保留并报告。不得将 SQL/参数当作事件额外字段，诊断不写回数据库、不重试事务。


✅ 初始化与清理复合失败统一使用StorageCore.StorageFailure，不再使用独立准备失败类型；underlying保留初始化主错误，cleanupErrors保留附加错误。未确认清理继续阻止旧作用域被复用，stop不丢弃多项清理错误。

## 基础相册实施契约

相册元数据和索引直接属于当前 media_files schema；领域 SQL 由 SQLiteMediaRepository 拥有。

## Passive state reads

SQLiteDatabaseStorage.stateSnapshot reports its own lifecycle evidence. Ready is set only after startup and recovery complete; stopped only after joined shutdown. A retained startup failure reports failed. Reading the snapshot performs no SQLite or filesystem operation and does not access a repository getter.

SQLite stateSnapshot returns the same StorageCore classified State as the Storage root and other children. DatabasePhase is Runtime; an actual backend failure is diagnostic health/issues. Reading never opens or accesses a repository.

## Video media rows

SQLiteMediaRepository reserves kind=video/MIME=video/quicktime/.mov rows without album_added_at. It uses existing dimensions/origin fields and explicit collection, so no new migration or second album table is needed. reservePhoto rejects video metadata. Shared ready/collection/deleting/deleted predicates and keyset pagination apply to both media kinds; SQL never validates a native asset or owns file copying.

SQLiteRepositories 提供一个当前 schema；SQLiteDatabase 只在 PRAGMA user_version 匹配当前标识时重开。空库和未知/旧 schema 经 GRDB barrier erase 清空全部表后，一次事务建表并写入当前标识。不注册历史迁移，不导入旧消息或媒体；同格式的事务、WAL、崩溃恢复与关闭屏障仍适用。

Task 领域在数据库发布前幂等建立 task_notifications 及未确认索引，使用同一 pool/外键/写事务。终态与通知原子写入，送达和退休分别确认；初始化失败沿既有路径关闭未发布的 pool。此表不导入旧消息协议，也不改变当前 schema 的开发期清库规则。

Light message previews read producer metadata from the existing evidence header without expanding source chunks. Delegated phase updates also update time; terminal projections include current-run finished_at. No schema migration, derived counter table or database reset is required.
