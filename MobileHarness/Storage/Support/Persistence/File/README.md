# File and Document Implementations

## Responsibility and implementation

LocalDocumentStore implements DocumentRepository with a bounded cached JSON envelope/version1, UUID revisions, process-local per-file CAS locks and atomic replacement. LocalFileStore implements BinaryObjectStore plus explicitly native directory/reservation/materialization methods used by ActionBindings model-artifact adapters.

## Direct relationships

Compiled in Storage; Foundation/Synchronization only. App supplies trusted roots, size/protection policy and codec values. Media/settings/context consumers receive protocols; native download adapters intentionally require filesystem paths.

## Lifecycle and failure contracts

Default document64KiB; file reservation32GiB. Confined paths reject traversal/symlinks and native capacity failures. Binary publication writes a UUID temporary file, synchronizes, closes and moves without overwrite; cleanup failure preserves both causes. Listing keeps at mostfour cursors, inspects128 nodes per page and closes on error/explicit close. Document cache changes only after durable success; corruption/version/conflict are explicit.

[Parent](../README.md)

Binary object contract: BinaryObjectStore describes byte objects only, with no file-protection or regular-file flags in its interface. File protection is configured when App constructs LocalFileStore; directory/non-blob keys are absent from object info. Preserve Media pending recovery through that neutral contract.

文档 envelope version 为 1，未知版本明确拒绝。读取有容量边界，更新遵循 revision/CAS 与原子写入；配置、偏好和传输记录复用同一契约。

## 待实现

- Cross-process document CAS and physical storage-protection acceptance remain outstanding.
