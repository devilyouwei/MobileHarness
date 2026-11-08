# Database table ownership — validation

2026-11-07. Scope: [requirements and plan](../completed/Database-Table-Ownership.md). Synthetic fixtures only; no real user logs are deleted by these tests.

## Fix and structural evidence

The reported invalidParameters occurs before SQL: MemoryHistoryWorkflow omitted optional requestID in its internal tool declaration. Registration and invocation now share one declaration. The end-to-end regression submits both single-request and global commands through UI history requests, Memory, Actions and real temporary SQLite, then checks cleared Prompts and preserved replies/messages/request business rows.

The SQLite backend now has eleven table directories, each with a typed GRDB record, column mapping, original schema/indexes, operations and README. Root repositories retain coupled transactions; public repository contracts and compilation boundaries remain stable. No new ORM dependency or schema version is introduced. Executing pre-refactor and post-refactor DDL in separate temporary in-memory SQLite databases yields identical normalized definitions for all 34 schema objects, including SQLite sequence, tables and indexes.

## Execution

- Production swift build passed with full Xcode.
- Focused test run completed all seven tests: UI-to-SQLite clearing; eleven-record round trip including nulls/BLOBs/keys; composite-key replacement rollback; schema separation; payload reopen/deletion/no resurrection; global cross-agent deletion; known-schema migration preserving IDs/payloads/foreign keys. Log: /tmp/mh-table-tests.log.
- Initial test compilation required explicit try inside Testing macros and await for async endTask; corrected before the seven-test pass.
- Initial check.sh stopped at repository filename policy: Swift extension filenames cannot contain +. Renamed the nine files to UpperCamelCase and updated documentation references before rerunning.
- Full check ordinary phase completed: main group 1,075 tests in three suites passed (64.579s); remaining ordinary targets also completed without failures. Architecture boundaries, six Python tests and strict formatting passed. Log: /tmp/mh-table-check.log.
- Final ./scripts/check.sh exited 0. LiveRuntimeTests explicitly completed 227 tests (206.507s), and all plist checks passed. NativePresentationTests only recorded suite startup and cameraNativeMetalDrawStopAndLayerHandoff start, with no test/suite completion. It is NOT counted as passing despite the script exit code; the same incomplete native-runner behavior was recorded before this change.
- All 20 affected Database design/requirement/validation documents passed relative-link checks. git diff --check passed.
- ./scripts/build-ios.sh exited 0: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero each reported BUILD SUCCEEDED; Agent/Skill and Live Activity resource checks passed. Log: /tmp/mh-table-ios.log.
- Signed physical iOS build succeeded as 0.1.0 / 2026110704. Strict deep code signature, 30 Agent/Skill assets, embedded Live Activity identity/version and executable freshness passed. Installed in place over 2026110703 on the paired iPhone 17 Pro; independent device inventory confirms 2026110704 (installation sequence 6208). No uninstall or user-data reset. Log: /tmp/mh-table-device-build.log; device install/before/after JSON and logs under /tmp/mh-table-device-*.
- Automatic launch was denied because the iPhone was locked (CoreDevice 10002, FBSOpenApplicationErrorDomain 7). Installation is verified; app startup and interactive clear-button acceptance are NOT verified. User must unlock and open the installed app. Launch evidence: /tmp/mh-table-device-launch.json and .log.

## Acceptance boundary

Automated routing/persistence tests and successful compilation do not establish native button interaction, real model behavior or physical-device visual acceptance. Those require separate observed evidence.

## Database-root table ownership (2026-11-07, subsequent refactor)

Scope: the user moved the ownership boundary from Database/SQLite/<Table> to Database/<Table>, including public DTOs, repositories, table schema/upgrade and workspace/media coordination. SQLite now contains pool/admission/shutdown and schema composition only. Shared contracts and cross-table facades reside at the Database boundary. Explicit Package.swift source ownership preserves the original SQL-free targets and the single GRDB target.

This validates the directory/initialization portion of [the approved independent-agent design](../completed/Message-Agent-Business-Separation.md), **not completion of its target schema**. The eleven existing physical tables remain; separate Assistant/Writer messages, generic agent_messages, removal of model_requests/message_media, raw HTTP capture and business lifecycle adaptation are not implemented by this portion. No device database was opened or migrated and no app was installed.

- The unknown-version pool.erase path is removed. Bootstrap accepts an empty version-zero database; unknown versions and populated unversioned databases throw without replacing records. Known mixed-log conversion remains table-owned and transactional.
- Added two temporary SQLite regressions checking the retained value, retained user_version and absence of newly created domain tables after rejected initialization.
- Initial check attempts failed to compile these new tests because Testing macros did not infer throwing read closures, and a synchronous GRDB fixture was initially declared async. Reads now return typed values before assertions; the fixture is synchronous. These failed attempts are not passing evidence.
- Module/import/source-owner boundary checks, six Python tests and strict formatting passed in the current check run. Full test execution is still running; log: /tmp/mobileharness-database-check.log.
- ./scripts/build-ios.sh exited 0. MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero each reported BUILD SUCCEEDED. The final app's 30 Skill/Agent assets and native Live Activity resource checks passed. Log: /tmp/mobileharness-database-ios.log.
- Relative file links in 25 affected Storage/overall/design documents were checked with zero missing targets. git diff --check passed.
- Compilation and synthetic fixtures do not establish real-model, native interactive UI or physical-device acceptance.


## Independent Agent schema replacement (2026-11-07)

This section records the subsequent ten-table rewrite; the eleven-table and no-reset results above are historical stages, not the current schema. Scope: [independent Agent design](../completed/Message-Agent-Business-Separation.md). The user explicitly authorized deleting old tables/code/data, adjusting history UI, and uninstalling the old physical-device application before installation. No data compatibility or migration is retained.

The implemented schema contains assistant_conversations, assistant_tasks, assistant_messages, writer_tasks, writer_messages, agent_messages, model_request_log, workspace_files, media_files and devices. Schema/version and current-table round-trip tests use temporary databases. The old-format test verifies erase/recreate rather than migration; reopening the current format retains new records, and future versions are rejected.

Regression findings corrected during this stage:

- Concrete SQLite communication methods now implement the asynchronous protocol requirements, avoiding dispatch to default invalidRecord implementations.
- Writer completion outbox retries remain alive through future backoff; pause releases the current claim, one claim is taken per delivery, and checks for newly due messages occur at most one second apart. Reopening and delivering 20 completed requests does not re-execute Writer work.
- A foreground task waiting for another user input remains active; only actual terminal states end the stored task. Consecutive task.start cancels and joins old effects before creating the next foreground scope.
- Rebuilding a history window preserves an active input awaiting ReACT even when its last model round is completed. The delayed-old-completion/new-delegation regression passes all 30 parameter combinations. Earlier invalidRecord failures are not passing evidence. Focused log: /tmp/mobileharness-deferred-fixed.log.
- History images use captured HTTP/local request bytes only; both Chat Completion and Responses image formats are covered. Clearing logs removes images and generation metadata, and late callbacks do not recreate logs. Camera/album fallback ports were deleted.
- Completion outbox tests cover stale claims and dead-letter after eight failures. Logs: /tmp/mobileharness-last-edge-tests.log (those cases passed, while the earlier delayed-completion test still failed in that run).

Final verification evidence:

- ./scripts/build-ios.sh exited 0 after the final production changes: all four schemes reported BUILD SUCCEEDED. Log: /tmp/mobileharness-complete-build-ios.log.
- Signed physical build 0.1.0 / 2026110705 succeeded; strict deep signature, 30 Agent/Skill resources and embedded Live Activity checks passed. Log: /tmp/mobileharness-complete-device-build.log.
- The first full check of this stage failed an obsolete UI expectation that restored images from lightweight message metadata; the test now requires no images without request logs. It also failed residentNativeStateSeedsOnceAndReadsNeverSampleSources and slowTrackingDispatchExecutesOnlyTheNewestPendingTarget while builds ran concurrently. No unrelated production behavior was changed to hide those failures. Its LiveRuntimeTests phase completed all 227 tests in 209.145 seconds; native presentation only logged startup/first-test start without completion and is not counted as passing. Log: /tmp/mobileharness-complete-check.log.
- In /tmp/mobileharness-final-idle-check.log, the corrected UI target (197 tests) and ordinary integration target (1,081 tests) passed, including both prior timing failures. The native phase was stopped when the final unused MediaStore.readForInput interface was removed; that interrupted run is not a final script pass. Media regressions now exercise complete StorageOwner reads, missing/deleted files and bounded queue behavior. The first focused recompile exposed a missing StorageFiles test import, corrected before rerunning.
- Relative links in 17 Database/module/overall design documents were verified with no missing targets; git diff --check passed.

Final cleanup/build and physical installation:

- Deleted the unused MediaStore.readForInput history shortcut. The updated focused run passed seven media/integration regressions and one history UI regression. Log: /tmp/mobileharness-final-media-tests2.log.
- ./scripts/build-ios.sh passed again after that deletion, with all four schemes successful. Log: /tmp/mobileharness-release-build-ios.log. The final signed device rebuild also passed; strict signature and the Agent/Live Activity resource checks were repeated successfully. Log: /tmp/mobileharness-release-device-build.log.
- On the paired iPhone 17 Pro, uninstalled dev.mobileharness.app version 2026110704 and independently verified the bundle was absent, then installed 0.1.0 / 2026110705. Device inventory confirms the new version, installation sequence 6272. This was a clean uninstall/install, not an upgrade preserving the old container. Evidence: /tmp/mobileharness-clean-uninstall.json, /tmp/mobileharness-clean-device-absent.json, /tmp/mobileharness-clean-install.json and /tmp/mobileharness-clean-device-after.json.
- The first launch was denied by iOS Security (CoreDevice 10002 / FBSOpenApplicationErrorDomain 3). Host signature verification passed; the profile expires 2026-11-13, includes this device and matches application/team entitlements. The user then confirmed developer trust and manually opened the app. A subsequent devicectl launch succeeded. Evidence: /tmp/mobileharness-clean-launch.log and /tmp/mobileharness-clean-launch-trusted.json.
- Copied only the new database and WAL to temporary local files for read-only inspection. Device data was not modified by inspection. user_version is 20261108, all ten expected business tables match exactly, integrity_check is ok, and foreign_key_check returns zero violations. There is one empty assistant conversation; all message/task/communication/log/workspace/media/device row counts are zero. No old business tables remain. Evidence: /tmp/mobileharness-clean-schema-evidence.json.
- This establishes installation, startup and clean schema initialization. It does not establish real-model conversations, visual history-page acceptance or physical-device Actions.

The /tmp/mobileharness-release-check.log ordinary phase failed one additional PlatformStateTests notification wait at its three-second host deadline; its native phase was stopped rather than counted as complete. The test helper now permits fifteen seconds of host scheduling while keeping exact snapshot/count assertions and bounded failure; production timing is unchanged. The final complete script run is /tmp/mobileharness-verified-check.log. Its ordinary phase passed the 1,081-test integration group, 197-test UI group and all remaining ordinary targets, including the notification regressions. The final script exited 0. LiveRuntimeTests completed all 227 tests in 207.170 seconds, and all plist checks passed. NativePresentationTests again logged suite/first-test startup without a completion result, so it is explicitly NOT counted as passing. No real-model or visual interaction acceptance was performed.

Final documentation verification: 27 affected design documents had no missing relative-link targets; git diff --check passed. Completed independent-schema, table-ownership and full-log plans are archived under docs/completed; the earlier broader Storage native/model acceptance record remains separately tracked.
