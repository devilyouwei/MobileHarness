# SQLite Infrastructure

## Responsibility and implementation

SQLiteDatabase is internal to StorageSQLite and owns DatabasePool, configuration, bounded write admission, migration execution, transaction dispatch and temporary-test-file cleanup. It accepts SQL migrations from domain adapters and contains no business schema/query.

## Direct relationships

StorageSQLite links GRDB.swift7.11.1 and Storage. App selects SQLiteDatabaseFactory; SQLiteDatabaseStorage creates and owns SQLiteRepositories; the domain adapters share this one pool/runtime namespace. GRDB/SQL types never appear in public repository contracts.

## Lifecycle and failure contracts

WAL, foreign keys, synchronous FULL, four readers; one writer/16 waiters, overflow busy, native SQLite busy timeout2s. Transactions are synchronous and cannot span model/file awaits. Committed-row diagnostics and exact query plans are backend-test capabilities, not generic interfaces. Temporary files are removed only after successful pool close.

[Parent](../README.md)

accept named domain-supplied migrations, including partial unfinished-message and unfinished-Task indexes. Generic database support owns pool/transactions only; ORM records and lifecycle SQL remain with the domains.

✅ 共享读写生命周期门最多接纳 64 个操作，写入仍最多 17 个；溢出 busy。beginClosing 同步拒绝新操作；shutdown 合并一个后台任务，加入在途操作后关闭池，失败原样返回且不重开。初始化失败同步关闭未暴露的池，保留迁移与关闭错误。临时文件仅在关闭成功后删除。

## 待实现

- Alternate database libraries/backends and cross-process application ownership are not implemented.

## Storage 容器关系

✅ 本目录的领域端口由 DatabaseStorage 发布；SQL 适配器统一归 Database/SQLite 编译，业务调用方不导入 SQLite 后端。

## 统一容器异常通道

✅ SQLiteDatabaseFactory/Storage/Repositories 把报告器传到 SQLiteDatabase；中央读写、迁移、准备、关闭异常原样保留并报告。不得将 SQL/参数当作事件额外字段，诊断不写回数据库、不重试事务。
