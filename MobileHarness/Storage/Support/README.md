# Common Storage Mechanisms

## Responsibility and implementation

Contracts owns backend-neutral interfaces/values; Memory owns bounded process-local stores/streams/leases/admission; Persistence owns concrete File and SQLite mechanisms. Domain schemas/queries remain in Chat/Tasks/Media/Devices.

## Direct relationships

The Storage target compiles Contracts/Memory/File only and depends on no project/third-party target. SQLite support compiles separately in StorageSQLite. Domains use the common contracts; App chooses implementations and owns roots/lifetime.

## Lifecycle and failure contracts

No global discovery, universal SQL/query DSL, business state transitions or backend fallback. Protocol completion/error/durability contracts are explicit. Individual source files expose public APIs through Swift modules; no umbrella Storage.swift is needed.

[Storage](../README.md)

## 待实现

- General state-transition/subscription feature and new persistent backends are not implemented.
