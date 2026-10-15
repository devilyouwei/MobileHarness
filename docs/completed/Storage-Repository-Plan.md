# Storage repository and backend separation

归档日期：2026-10-15。原需求完成范围：Storage 领域契约与具体后端分离及调用迁移。历史验证结果和独立验收限制保留如下；当前实现以源码 README 为准。

Updated2026-10-15. ✅ Implemented; native acceptance remains separate.

## Decision and scope

Keep one first-level Storage module directory. Chat/Audio/Media/Tasks/Devices own their data contracts and policy. Support owns backend-independent Contracts, bounded Memory mechanisms and persistent File/SQLite infrastructure. Domain SQL stays in the owning directory but compiles only in StorageSQLite. Swift modules/public declarations supply APIs; no Storage.swift barrel or global singleton is needed. SQLiteRepositories is an explicit construction/lifecycle owner for one backend family.

The common Storage target has no project/third-party dependencies, and Audio does not require SQLite. Independent products permit using common/domain libraries without the application aggregate. StorageSQLite alone links GRDB.swift7.11.1 and the internal domain contracts. App chooses File/SQLite implementations and paths; Agents/Actions/feature workflows consume protocols.

## Contracts and preserved behavior

DocumentRepository and BinaryObjectStore have working File and Memory implementations. Document CAS, corruption/size errors, non-overwrite, confined object keys, bounded reads/listing and explicit durability are covered by shared tests. File protection/native directory materialization are backend construction/capabilities, not universal binary-object parameters. No speculative document-database driver or generic ORM is added.

ChatRepository exposes async record operations with neutral owned values; TaskRepository handles committed creation/completion; MediaRepository and DeviceRepository isolate metadata/mapping. Chat/Task namespaces must match. Default standalone chat/Task storage is explicit ephemeral memory and opens no temporary SQLite. Production business IDs remain committed SQLite AUTOINCREMENT references; runtime identities remain UUID/opaque strings.

Preserve records-v1 schema, per-complete-message/ReACT commits, zero delta writes, original-position Task compression,50-item pages, exact evidence deduplication, bounded previews/fingerprints, media pending/ready compensation and native mapping. Shared StorageOperationGate owns FIFO serialization across async awaits, one operation/16 waiters. Captured checkpoints use joined store-owned work so cancelled callers still persist terminal data; ordinary operations honor cancellation. No SQL transaction spans a model/native/file await.

## Cleanup and validation

Remove aggregate RecordDatabase, database-bound conversation facade, default SQLite allocation in memory-only consumers, direct backend dependencies and unused feature state. App-owned settings document construction replaces business-layer filesystem discovery; Agent contexts use Storage memory state. Preserve existing SQLite data, original media, model weights, credentials and unrelated worktree changes; no legacy importer or signing changes.

✅ Shared File/Memory, namespace, publication/gate and actual cancelled-caller regressions; existing message/history/photo/Task/Bluetooth regressions;100000-message indexed-query/write-range/memory benchmark; boundary/format/plist/resource checks and unsigned iOS device build. Required full check and simulator limitations, exact logs/counts and separate physical/live-model acceptance are recorded in [validation history](../validation/Validation-History.md#2026-10-15--storage-repository-and-backend-separation).

❌ Additional Chat/document-database backends, durable PCM, general state transitions, cross-device synchronization and live/physical acceptance are not implemented by this directory/interface change.

[Current Storage design](../../MobileHarness/Storage/README.md) · [Overall design](../../MobileHarness/README.md) · [Broader architecture plan](../requirements/technical/Core-Architecture-Improvement-Plan.md)


✅ Configuration preservation correction (2026-10-15): original settings/preferences/transfer paths and unchanged File envelope1 are restored, along with the existing CapturedPhotos root. Numeric-prefixed App paths were unintended migration scope and are removed. Agent runtime payloads now use Storage memory state; no Context JSON is loaded/saved. No Keychain/weight deletion, old-business-data importer or dual-format fallback. See validation history for checks and physical acceptance limits.


✅ Lifecycle/ORM correction implemented (2026-10-15): insert completed user messages once at acceptance; reserve unfinished Task/Assistant identities first; update validated single-snapshot memory during work; flush content/status at each producer completion. Use existing GRDB ORM records privately, not a new dependency or global identity-map singleton. Remove all production Agent context JSON and duplicated live-state recovery blobs. Preserve independent per-message/ReACT commits, failure retry, indexed queries, runtime UUID correlation and original App configuration.


✅ Implemented (2026-10-15): User admission correction: after final ASR/typed-input acceptance, insert completed content and allocate the user ID in the same transaction; only producers needing an ID during unfinished work reserve empty rows.


✅ Implemented (2026-10-15 current-dialog hardening): Harden current dialog publication/recovery and admission checks without new directories/schema/legacy compatibility. Database rotation is atomic; pending memory synchronization must resolve before later work. SQL write preconditions close races while preserving indexed reads, original archived-message late updates and zero delta I/O.


✅ Implemented (2026-10-15 Task record visibility): Repair the UI consumer of compressed SQL timeline pages: a collapsed Task source is a partial projection of its complete durable source list; page append must retain per-page summaries. Do not change storage schema, import old formats or replace SQL-backed paging with whole-dialog reads.

## 原核心架构计划第 4 项完成记录

2026-10-15：存储抽象接口与后端分离已实现，原需求从未实现清单移出。以下保留原计划的范围与验收约定；实际实现和验证以本文件前文及 Storage README 为准。

按实际能力定义存储接口，调用方依赖所需契约；内存、文件、数据库等具体实现由组合根选择和注入。按文档、文件、记录查询/写入、状态、流或租约等职责拆分，不用一个万能接口掩盖不同完成语义，也不只为抽象而新增实现。

- 通用存储契约由 Storage 拥有；业务专用消费契约可由业务模块拥有，App 适配连接。Storage 不反向依赖 App、Agents、Actions 或 UI。
- 契约明确一致性、事务边界、版本冲突、持久化成功条件、容量/溢出、取消及关闭行为。内存转换成功不等于落盘成功，文件发布与数据库提交也不能冒充同一事务。
- 调用方只获得必要的读写能力，不访问具体后端、文件布局或缓存。错误显式传播，不在持久化失败后静默切换为内存成功。
- 各实现使用共享契约测试；针对持久化实现另测重启、损坏和事务失败。逐步迁移真实调用方，移除被替代的直接依赖和重复实现。

本项为第 1 项提供状态存储接口，也应与 [SQLite 业务记录迁移计划](Prefix-Numeric-ID-Plan.md) 协调，避免固化正在被替换的文件布局或 ID 分配器。✅ SQLite 业务记录迁移已完成；本项进一步拆分接口、目录和编译边界，保持已有记录结构和提交/恢复语义。

验收：通过接口注入不同实现、权限与并发契约、显式存储失败、持久化恢复，以及无基础模块反向依赖。


✅ Implemented (2026-10-15 automatic history paging): History fetches50-item cursor pages automatically when lazy-list paging footers appear; each expanded Task paginates independently. No storage query/schema change or eager whole-dialog loading. Page requests use cursor/ticket fences, cancellable view tasks and explicit error retry.
