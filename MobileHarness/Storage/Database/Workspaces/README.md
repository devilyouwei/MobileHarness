# Workspace storage

StorageDatabase owns current workspace index contracts and WorkspaceStore, which coordinates
StorageFiles primitives with SQLite metadata. Actions owns formats, editing, rendering and acceptance.
Source bytes exist only at agent/task_N/relative-path. Reads enumerate that confined directory and
reconcile metadata; they never reconstruct missing content from model logs. Missing directories fail.
Writes claim a SQL lease, atomically replace changed files, remove deleted files and commit the index.
A failed collection write leaves actual files as a draft; the next read reconciles their index. Startup
clears abandoned leases and marks those workspaces dirty, without replaying model work.
Current tokens fence stale writers; they are not addressable versions. Reader snapshots are values or
short-lived render/export files owned by their consumer. Deletion retains a marker until cleanup succeeds.

A directory snapshot is read in one DiskFileStore actor turn and checked against SQL before/after sampling. A concurrent collection write returns explicit busy rather than presenting a mixed snapshot. A missing file in an accepted index is an error; interrupted dirty collections reconcile their index from the actual directory.
