# ModelKitRuntimeTests

Purpose: validate shared ModelManager registration, identity, loading, typed capability acquisition and lifecycle. Design goals: deterministic contract tests and explicit separation of real-model acceptance.

- ✅ Tests use explicit contexts for isolated adapters; shared-container behavior is tested in ModelKitRuntimeTests.
- ✅ Invalid inputs and lifecycle failures remain observable; no production fallback implementations are added for tests.
- ❌ Default test success does not establish physical-device quality or stability. Real-weight tests require local artifacts and opt-in flags.

Update this README when test scope or lifecycle contracts change.

- ✅ Shared provider/load identity, cancelled shared-load waiters, failed-load retry, retained handles, explicit unload waiting, shutdown cancellation and backend cleanup barriers.
- ✅ Registration and cross-model loader limits reject excess work without a hidden queue.

✅ Tests cover the sole typed get API, shared construction, separate availability/residency, retain versus releaseWhenIdle, protection of active leases and provider reuse after pressure eviction. Isolated resource fixtures explicitly import ModelManagement SPI.


✅ Default capability bindings are atomic, reject duplicates and unsupported mappings, and share lifecycle behavior with explicit-ID acquisition. No standalone resolver exists.

✅ Production assembly tests cover concurrent first access, shared manager identity, conflicting roots and terminal shutdown. Runtime tests use ModelAssembly SPI for isolated containers; production has no public manager constructor.

✅ Exclusive resource admission rejects overlapping requests without loading extra weights and allows reuse after lease release.

✅ Stale lease release and cancellation registration cannot affect a newer active request; shutdown invokes the current cancellation handler.

## Local model resources — current contract

✅ ModelArtifactTests covers endpoint validation, unsafe required paths/prefix selections, maintenance through retained handles, manager-preserving removal, incomplete Hub snapshot rejection, successful SDK-contract installation, cancellation, symlink rejection, interrupted-stage restart, malformed receipt failure and bounded ZIP/deflate installation through fixtures. ❌ Physical network/background/device acceptance remains pending.

✅ 资源取消测试覆盖底层 URLError.cancelled 的清理，以及安装完成后迟到的取消不改变已安装状态。❌ 真实 iOS 网络/后台生命周期仍需单独验证。

✅ installedFilesSurviveTransferIndexWriteFailure reproduces a failure after file publication and asserts installed status, explicit bookkeeping warning and safe late cancellation. ❌ It does not reproduce the phone filesystem/lock state.

✅ Failed deletion keeps valid installed files visible with a specific removal warning; successful retry clears the warning.

✅ HARNESS_TEST_YOLO_ARCHIVE opts into testing the actual production YOLO ZIP through Management checksum, native extraction and required-file validation; no weights are committed. ❌ Publication uses fixture storage, so device receipt/protection acceptance remains separate.

✅ Artifact snapshots preserve incompatible revision errors, so stale Nemotron installations can be explicitly removed and re-downloaded.


✅ Restored HF generations preserve staging before reattachment; failed requests retain resumable records and explicit cancellation removes them. This supersedes the previous discard-before-restart contract.

✅ RuntimeBoundaryTests cover invalid manager configuration, nondefault limits reaching Core resources, manager state projection, failed admission and unload/shutdown. Isolated contexts specify their gate/waiter limits explicitly; ModelManager initialization propagates configuration errors.


✅ Fixtures use UUID/opaque runtime strings and committed database business references; concurrency, restart, invalid-ID and failure behavior remain covered.

## Identity ownership

✅ Runtime and foundation identities use opaque protocol strings or Foundation UUID; no project ID-generator dependency exists. SQLite-backed Storage publishes committed business references and App injects repositories/maps native Bluetooth identities. Tests preserve caller identity, cancellation and failure semantics. See [current storage design](../../MobileHarness/Storage/README.md) for relational allocation and persistence.
