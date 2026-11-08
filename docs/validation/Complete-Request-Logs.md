# Complete request logs — validation

2026-11-07. Scope: [requirements](../completed/Complete-Request-Logs.md). All data used below is synthetic; no real user logs are deleted.

## Automated evidence

- Added regressions for full submitted-image bytes across SQLite reopen, detail/export decoding, lightweight context, single/global physical log deletion, cross-agent ownership, unchanged business rows/replies/timing, late callback isolation and current-schema upgrade with preserved keys/sequence/FKs.
- Reworked previous ephemeral-history fixtures to assert that the submitted model image survives Camera close/reopen, reused preview_N, album saving/deletion, while the original album image remains independent.
- Writer tests cover no separate history media-file publication and continuation/native-tool-pair reconstruction remaining unchanged after log deletion.
- Initial direct swift test invocation used Command Line Tools and could not invoke Metal. Subsequent checks use full Xcode through DEVELOPER_DIR/script configuration.
- Initial focused run: three passed, two assertion defects (JSON escaping and AUTOINCREMENT gaps) corrected to decode exported JSON and compare actual prior sequence.
- Initial full check exposed eight old assumptions about prompt JSON in business records/ephemeral images and one byte metric implementation issue. These were corrected to read independent logs and count UTF-8 storage bytes. Writer continuation was also decoupled from deletable prompt snapshots.

## Final execution

- Executed ./scripts/check.sh twice. Architecture/dependency checks, six Python tests, strict formatting and plist checks passed. The first run exposed the failures described above; the second retained two assertions in a Writer fixture that still read the intentionally lightweight current context. That fixture now explicitly reads complete records.
- Final ordinary-suite rerun: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip 'LiveRuntimeTests|NativePresentationTests' exited 0. The main suite reported 1,072 tests in three suites passed (64.785s), and the remaining ordinary test targets completed without failures. This includes all three new complete-log tests and the Writer image/continuation/clearing regressions. Log: /tmp/mh-complete-logs-main-final.log.
- Both check.sh runtime phases explicitly completed LiveRuntimeTests: 227 tests, latest 208.293s. NativePresentationTests only recorded startup and cameraNativeMetalDrawStopAndLayerHandoff start, without test/suite completion. It is NOT counted as passing, regardless of runner exit behavior. This matches the earlier limitation recorded in Camera-Session-Gallery validation. Latest full check log: /tmp/mh-complete-logs-check-final.log (exit 1 due to the subsequently corrected Writer fixture assertions).
- ./scripts/build-ios.sh exited 0: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero each reported BUILD SUCCEEDED. Agent/Skill assets and native Live Activity packaging checks passed. Log: /tmp/mh-complete-logs-ios.log.
- Final changed-file strict formatting and git diff --check passed. Current technical READMEs were reconciled with the independent log schema and Writer business-evidence restoration.

## Acceptance boundaries

No real model request, native visual interaction or physical-device installation/acceptance is claimed in this change. The UI code is compiled by the iOS build; confirmation, button layout and image display still require device/native visual acceptance.

## 2026-11-07 — Physical-device installation

At the user's request, built/signed current source as 0.1.0 / 2026110703 using existing local signing settings and a command-only version override. Physical iOS build, strict deep signature verification, 30 Agent/Skill assets, embedded Live Activity identity/version and executable freshness checks passed. Installed in place over 2026110702 on the paired iPhone 17 Pro (installation sequence 6176); independent device app inventory confirms 2026110703, and devicectl launch succeeded. No uninstall or user-data clearing was performed. This establishes installation and system launch only, not native log-clearing/image interaction or live-model acceptance. Evidence: /tmp/mh-log-device-0703-build.log, install/launch/apps .json and .log files.
