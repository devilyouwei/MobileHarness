# Database directory responsibilities — validation

2026-11-08. Scope: [plan](../completed/Database-Directory-Responsibilities.md). This change reorganizes code/ports without changing table definitions, schema version or persisted data. No physical-device install/reset was performed in this follow-up.

## Earlier directory-only phase

- Database root contains only DatabaseStorage, SQLiteDatabase, SQLiteDatabaseStorage, SQLiteRepositories and SQLiteSchema. Shared owns common business contracts/history/SQL coordination; the SQLite subdirectory is removed.
- The connection receives schema initialization from outer assembly and no longer refers to table/schema types. Table-specific recovery, message association, summary invalidation, role projections and query scope live with their table owners.
- Task and Chat contracts are decomposed into capabilities; OutputGateway accepts only communication, Assistant worker foreground/communication, and Writer worker local tasks/communication. Aggregate ports remain at assembly/history transaction boundaries. Compiled targets and dependencies remain unchanged.
- A new narrow-interface test verifies real SQLite protocol dispatch, idempotent communication, foreground completion, invalid receiver rejection and absence of unintended Writer task creation. The raw HTTP test uses the narrowed log interface.

## Earlier phase checks

- Production swift build passed: /tmp/mobileharness-directory-build.log.
- Focused tests passed nine test functions, including 30 parameter combinations for delayed Writer completion/new delegation, plus continuous foreground switching, schema/version checks, composite-key rollback, raw HTTP/no-resurrection and outbox stale claims/retry exhaustion. Log: /tmp/mobileharness-directory-tests.log.
- Boundary checks initially failed on the script's old ConversationHistory source path. Updated the path; /tmp/mobileharness-directory-boundaries2.log passes all module/source ownership checks, including new root-core and narrow communication checks.
- Relative links in 21 Storage/overall design documents passed; git diff --check passed.
- Full check and four iOS builds are recorded below after completion. Compilation and fixture tests do not establish real-model, native visual UI or physical-device acceptance.

## Complete business/API separation

The latest user instruction superseded the aggregate facade retained above. ChatRepository, TaskRepository, SQLiteChatRepository and SQLiteTaskRepository are removed. Assembly now exposes separate Assistant conversation/message/task, Writer message/task, log and Agent communication ports. Shared contains only encoding, record keys and paging. Assistant history/DTOs/SQL belong to AssistantMessages; Writer has independent records/journal/SQL with no Assistant summaries, archive rotation or context binding. Writer journal reads use task metadata, not a generic dialog interface.

Call sites in application composition, AgentRuntime, Assistant processing, Writer container/history/notifications and Actions history use explicit ports. UI receives role-owned projections. A new real-SQLite test verifies repeated input keys remain private and each message port rejects the other Agent's IDs. Existing log-deletion, task lifecycle, outbox and history tests are being adapted to independent ports; no compatibility alias is retained.

Intermediate production build passed at /tmp/mobileharness-decoupled-build6.log. Boundary checks passed at /tmp/mobileharness-decoupled-boundaries.log. Subsequent compilation runs detected stale fixture aggregate accesses and Writer DTO mismatches; those are compilation findings, not test passes. Final checks follow below.

## Regression findings and corrections

- The first focused execution passed independent schema, private message address isolation, narrow task/communication ports, raw HTTP/no-resurrection and consecutive foreground starts. Writer completion cases exposed an incorrectly qualified SQL `json(?)` function after helper extraction; restored the SQLite function call without changing outbox semantics.
- The first full check's main integration phase ran 1,083 tests and reported two issues: Writer detail decoding still required Assistant taskCompressions; a separate tracking test failed its newest-target assertion under concurrent execution. Updated the UI-owned decoder to accept Writer projections without foreground summaries. The tracking test is rerun independently before deciding whether a production change is warranted.
- Independent injection now validates common storageScope at Assistant/Writer assembly, including Writer history, tasks, communications and logs. Added mixed-database rejection assertions; ports are not silently rebound to another instance.
- Current Storage/overall/Writer/Chat documentation links were checked in 23 files with no missing targets. No retired aggregate repository identifiers remain in Swift production or test source.

## Final automated verification

- Focused regression rerun passed six test functions, including 30 Writer completion/FIFO combinations; it covers Writer detail decoding, whole-library log clear/no-resurrection, cross-Agent address rejection, mixed-database rejection and the separately rerun tracking case. Evidence: /tmp/mobileharness-decoupled-focused2.log.
- ./scripts/check.sh exited 0 on the final code: /tmp/mobileharness-decoupled-check2.log. Main integration: 1,083 tests passed; UI: 197 tests passed; LiveRuntimeTests: 227 tests passed in 208.284 seconds. Other test targets, boundary/source-ownership checks, six Python tests, strict Swift formatting and plist checks also passed. The previous tracking failure did not recur in this full run; no unrelated tracking implementation was changed.
- NativePresentationTests logged two completed tests and started cameraNativeMetalDrawStopAndLayerHandoff, but did not emit a suite-completion result. The script exit code does not establish full native presentation acceptance. This remains distinct from the successful automated suites above and from physical-device acceptance.
- This follow-up does not change SQLite table definitions or schema version, reset application data, install on a physical device, or claim real-model validation.

- ./scripts/build-ios.sh exited 0; MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero all reported BUILD SUCCEEDED. Evidence: /tmp/mobileharness-decoupled-ios.log. This is simulator compilation, not physical-device or full native presentation acceptance.
