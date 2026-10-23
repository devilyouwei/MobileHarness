# Device Record Contract

## Responsibility and implementation

DeviceRepository.swift exposes async stable native/business mapping, selected device and reconnect configuration. SQLiteDeviceRepository.swift owns devices schema/indexes/SQL and compiles only in StorageSQLite.

## Direct relationships

StorageDevices depends only on Storage. Actions consumes the protocol and PlatformKit receives the original native identity; this directory contains no transport or reconnect workflow.

## Lifecycle and failure contracts

Committed device keys remain stable across native-name updates. Selection updates atomically clear the previous selection and reject a missing target; native identifiers retain their original format. Writer failures propagate. No device motion or reconnect success is fabricated from a record.

[Storage](../../README.md)

## 待实现

- Additional record backends and physical-radio acceptance are separate work.

## Storage 容器关系

✅ 本目录的领域端口由 DatabaseStorage 发布；SQL 适配器统一归 Database/SQLite 编译，业务调用方不导入 SQLite 后端。
