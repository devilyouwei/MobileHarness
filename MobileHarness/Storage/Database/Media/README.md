# Media Records and App Album

## Responsibility and relationships

MediaRepository defines file reservations and independent album collection records. CapturedPhotoStore combines injected metadata and byte stores; SQLiteMediaRepository owns the SQL adapter in StorageSQLite. StorageMedia depends on StorageCore and StorageFiles only. Actions owns photo validation, native effects and presentation; Storage never imports UI, PlatformKit or Agents.

AlbumRecord defines media metadata (MIME, dimensions, optional capture time, camera/import origin), collection time, original creation time and stable keyset cursors. CapturedPhotoStore exposes capture save/read, explicit collect, importPhoto, albumPage, readAlbum and deleteAlbum. Camera/model/history reads retain their original source/session/input authorization; user album reads require actual ready collection.

## Publication, collection and recovery

✅ Camera capture remains a ready JPEG file until collect commits album_added_at. Ignoring a preview does not collect it. Imports reserve metadata with collection intent before publishing bytes; only ready files become visible. A crash after publication can recover pending files by matching byte size without losing import intent. Legacy records have null collection time and remain available to authorized history reads without appearing in the album.

Non-overwriting file publication occurs outside SQL transactions. Failed publication preserves the original error and any compensation error. The original bytes are immutable. Camera JPEG remains limited to 4 MiB; imports permit JPEG/HEIC/PNG up to 32 MiB, with format/dimension validation supplied by the caller. Raw model/history reads retain their 4 MiB bound.

## Capacity and concurrency

✅ One StorageOperationGate serializes file/metadata combinations with 16 bounded waiters. Defaults are 32 files/128 MiB; production uses 1024 retained files/2 GiB. Reject policy never evicts. FIFO policy may evict only uncollected files, oldest first; protected collections alone exceeding admission capacity reject the new file. Failed/unavailable/deleted rows remain as evidence.

Queries return at most 40 photos, ordered by capture time (creation time when absent) and numeric stable ID descending. A cursor uses both values; deleting an earlier row cannot shift later pages as offset pagination would.

✅ Deletion commits state=deleting before removing bytes, then commits deleted. Neither state appears in album queries or authorized history image reads. Failed cleanup is explicit; subsequent operations retry at most 128 pending deletions before proceeding. Failed cleanup can block storage operations until resolved; it cannot resurrect a deleted photo. Cleanup lists at most 128 names per operation, matches only owned capture/import/temp naming conventions and retains pending/ready resources.

Native device acceptance is tracked in [album validation](../../../../docs/validation/Album.md).

[Storage](../../README.md) · [Database](../README.md)

删除回执区分逻辑删除成功与文件清理问题；逻辑提交后即从当前UI列表移除，清理失败明确提示并保留恢复状态。

## Movie publication and image isolation

saveVideo accepts a regular .mov source bounded at512MiB and validated video/quicktime metadata, reserves a video row, imports the file and commits ready. It does not collect automatically. collectVideo verifies matching owner and actual byte count before album inclusion. videoURL requires either exact photos/source/session/input ownership or an existing ready album collection. discardVideo is limited to uncollected matching-owner videos and joins physical cleanup. Generic album pagination/export/deletion includes both MIME families.

The historical PhotoMetadata/AlbumPhotoRecord names and photo_width/photo_height/photo_origin columns are shared metadata carriers; video duration is native-asset-derived above Storage. Image reserve/import/collect and byte reads reject video; 4MiB model/history and32MiB photo-import budgets remain unchanged. Videos share1024-file/2GiB production retention and the16-waiter operation gate; collected files are never evicted. Recovery recognizes owned .mov names, pending publication and deletion, without interpreting video contents.
