# Backend-independent Contracts

## Responsibility and implementation

DocumentRepository supplies typed Codable snapshots, UUID revisions, optimistic save and replacement. BinaryObjectStore supplies bounded reads/info, non-overwriting put, remove and bounded best-effort listing. StorageDurability explicitly distinguishes memory and persistent success. RecordStorageError, BusinessRecordID and ContentFingerprint are shared values/validation, never allocation services.

## Direct relationships

Compiled in Storage; Foundation/CryptoKit only. Domain/App consumers use protocols and immutable values. Concrete File/Memory/SQLite mechanisms implement their own applicable contracts.

## Lifecycle and failure contracts

Keys are confined relative names; listing cursors are opaque and at most128 items/steps. Cancel/close, conflict, capacity, ownership and publication errors are explicit; BinaryPublicationError retains original and cleanup failures. Native filesystem directory materialization is a separate capability, not simulated by every binary backend.

[Parent](../README.md)

Binary object contract: BinaryObjectStore describes byte objects only, with no file-protection or regular-file flags in its interface. File protection is configured when App constructs LocalFileStore; directory/non-blob keys are absent from object info. Preserve Media pending recovery through that neutral contract.

StateRepository: synchronous typed read/replace for a single process-local owned snapshot; no codec/database APIs or hidden durability. Owner validates bounds and serializes transactions.

RecordStorageError.conflict explicitly reports a repository precondition invalidated by a concurrent/current-dialog change; it is distinct from invalid content, missing records and busy admission.

## 待实现

- 暂无本目录独立实现待办；领域仓库接口由对应领域拥有。
