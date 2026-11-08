# Database table ownership and log-clear parameter regression

后续设计（2026-11-07，已完成并归档）：[独立 Agent 业务与纯通信表方案](Message-Agent-Business-Separation.md) 将 Assistant/Writer 私有完整消息和任务分开，新增 agent_messages 仅记录通信，不建立 writer_executions 或委派任务表；共享原始 HTTP 日志，删除旧 model_requests/message_media，清理重复字段。下文“11 表、字段不变”仅限当时目录整理范围。目录归属、新表与调用方已经按后续方案实现；整体验证与清洁真机安装已完成，证据跟随该方案。

2026-11-07: user requests fixing the physical-device Prompts clear failure (invalidParameters) and organizing Database by table, ORM-style. The request explicitly authorizes the per-table directories required below; no new module/dependency is introduced.

## Fix and scope

MemoryHistoryWorkflow declared History.Conversation.clearLogs with no optional parameters, so requestID was rejected while constructing the internal tool call, before Action/SQLite execution. Use one shared InternalTool declaration with optional requestID for registration and invocation. Preserve user-origin authorization, explicit failures, internal result handling and no model ReACT. Verify both single-row and whole-library clearing through the actual UI request source/Memory/Gateway/Action/SQLite path, not only repository tests.

## Table ownership

Keep StorageSQLite as the only GRDB target. Under Database/SQLite create AssistantConversations, Messages, AssistantTasks, WriterTasks, AgentDelegations, ModelRequests, ModelRequestLog, WorkspaceFiles, MediaFiles, MessageMedia, Devices. Each owns one table's schema/index definitions, a typed GRDB record with explicit field mapping, and its relevant persistence/query operations. Use the already-integrated GRDB record APIs, no additional ORM or dependency. Table rows are internal and do not escape foundational storage contracts.

SQLiteDatabase retains the pool/admission/shutdown. SQLiteSchema owns bootstrap and the existing known-version upgrade, referring to table-owned schema definitions. Repository public types/protocols and compiled targets remain stable. Single-table repositories move to the corresponding directory. The large Chat/Tasks implementations split into table-owned extensions/services; root facades retain only cross-table transaction orchestration and projections whose invariants span tables. Use the same transaction connection for coupled writes; table helpers never open a second transaction. Workspace lease/metadata operations belong to writer_tasks; file index belongs to workspace_files; request/media links belong to message_media. Do not copy SQL or leave replaced implementations in parallel.

Public Chat/Tasks/Media/Devices/Workspaces contracts remain in their existing target directories, because these expose multi-table capabilities to callers, not backend row types. Update Package.swift README exclusions, all current source links, owning READMEs and the overall technical design. Every new table directory has a README documenting fields/keys, relationships, operations, lifecycle and failure contracts. Existing schema version/table names/columns, IDs, counters, data and migrations remain unchanged by this reorganization.

## Validation

The integration test target directly uses the existing GRDB dependency for table-record round trips; runtime target boundaries remain unchanged. Add an end-to-end single-request/global log clear regression; retain unchanged conversation/message/business evidence and late-callback isolation. Test typed table mappings (including optional fields/BLOBs/composite keys), schema bootstrap/known upgrade, FK/uniqueness and rollback invariants. Existing real-SQLite conversation/Task/Writer/media/device tests cover behavioral equivalence. Check that each physical table has exactly one schema/record owner and all table code stays in StorageSQLite. Run ./scripts/check.sh and ./scripts/build-ios.sh; inspect actual test completions. Record known native-runner incompletion separately from normal tests and compilation. Build/install an updated physical-device version for user verification after checks; installation does not prove interactive clear acceptance.
