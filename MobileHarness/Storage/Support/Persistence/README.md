# Persistent Backends

## Responsibility and implementation

File implements confined binary objects and JSON documents. SQLite implements shared pool/configuration, bounded write admission and migration execution; domain adapters supply schemas and operations.

## Direct relationships

File belongs to dependency-free Storage. SQLite belongs to StorageSQLite, which alone links GRDB. App constructs both through explicit configuration; domains consume applicable protocols.

## Lifecycle and failure contracts

Durability and atomicity are capability-specific. A database transaction cannot include file publication, model generation or device effects. Failures retain original causes and never switch to an in-memory success.

[Parent](../README.md)

## 待实现

- 暂无本目录独立实现待办；其他后端尚无具体实现计划。
