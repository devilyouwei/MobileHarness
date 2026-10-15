# Media Records and JPEG Delivery

## Responsibility and implementation

MediaRepository.swift defines metadata reservation/state/read contract. CapturedPhotoStore.swift owns JPEG policy and pending/publication/ready compensation over injected MediaRepository and BinaryObjectStore. SQLiteMediaRepository.swift owns media_files schema/SQL and timestamp/key names; it compiles only in StorageSQLite.

## Direct relationships

StorageMedia depends only on Storage. App chooses metadata and byte backends; camera/history consumers use owned media IDs. Audio owns live PCM, while this directory indexes retained media files. No camera/album/codec/native effects are implemented here.

## Lifecycle and failure contracts

StorageOperationGate serializes one operation/16 waiters across backend awaits; reads cannot reconcile or clean an in-progress publication. Defaults32 files/128MiB, App1024 files/2GiB, JPEG4MiB, reject/FIFO policy. Non-overwriting publication happens outside database transactions; ready is required before ID delivery. Pending recovery checks regular-file size. Cleanup inspects128 names per operation with a bounded listing cursor, closes it on errors and preserves unrelated files. Failed/unavailable rows retain references; cleanup failure preserves both causes. Reads check producer/session/input or original source/input.

[Storage](../README.md)

Binary object contract: BinaryObjectStore describes byte objects only, with no file-protection or regular-file flags in its interface. File protection is configured when App constructs LocalFileStore; directory/non-blob keys are absent from object info. Preserve Media pending recovery through that neutral contract.

## 待实现

- Current producer is JPEG only; video/audio/document producers and real camera acceptance remain outstanding.
