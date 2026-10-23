# ModelKitRuntimeTests

✅ 显式 gate／租约测试验证非终止暂停取消并加入活动推理、拒绝旧接纳、恢复复用权重和终止后不可恢复。

Purpose: validate shared ModelManager registration, identity, loading, typed capability acquisition and lifecycle. Design goals: deterministic contract tests and explicit separation of real-model acceptance.

- Tests use explicit contexts for isolated adapters; shared-container behavior is tested in ModelKitRuntimeTests.
- Invalid inputs and lifecycle failures remain observable; no production fallback implementations are added for tests.

Update this README when test scope or lifecycle contracts change.

- Shared provider/load identity, cancelled shared-load waiters, failed-load retry, retained handles, explicit unload waiting, shutdown cancellation and backend cleanup barriers.
- Registration and cross-model loader limits reject excess work without a hidden queue.

Tests cover the sole typed get API, shared construction, separate availability/residency, retain versus releaseWhenIdle, protection of active leases and provider reuse after pressure eviction. Isolated resource fixtures explicitly import ModelManagement SPI.

Default capability bindings are atomic, reject duplicates and unsupported mappings, and share lifecycle behavior with explicit-ID acquisition. No standalone resolver exists.

Production assembly tests cover concurrent first access, shared manager identity, conflicting roots and terminal shutdown. Runtime tests use ModelAssembly SPI for isolated containers; production has no public manager constructor.

Exclusive resource admission rejects overlapping requests without loading extra weights and allows reuse after lease release.

Stale lease release and cancellation registration cannot affect a newer active request; shutdown invokes the current cancellation handler.

## Local model resources — current contract

ModelArtifactTests covers endpoint validation, unsafe required paths/prefix selections, maintenance through retained handles, manager-preserving removal, incomplete Hub snapshot rejection, successful SDK-contract installation, cancellation, symlink rejection, interrupted-stage restart, malformed receipt failure and bounded ZIP/deflate installation through fixtures.

资源取消测试覆盖底层 URLError.cancelled 的清理，以及安装完成后迟到的取消不改变已安装状态。

installedFilesSurviveTransferIndexWriteFailure reproduces a failure after file publication and asserts installed status, explicit bookkeeping warning and safe late cancellation.

Failed deletion keeps valid installed files visible with a specific removal warning; successful retry clears the warning.

HARNESS_TEST_YOLO_ARCHIVE opts into testing the actual production YOLO ZIP through Management checksum, native extraction and required-file validation; no weights are committed.

Artifact snapshots preserve incompatible revision errors, so stale Nemotron installations can be explicitly removed and re-downloaded.

Restored HF generations preserve staging before reattachment; failed requests retain resumable records and explicit cancellation removes them.

RuntimeBoundaryTests cover invalid manager configuration, nondefault limits reaching Core resources, manager state projection, failed admission and unload/shutdown. Isolated contexts specify their gate/waiter limits explicitly; ModelManager initialization propagates configuration errors.

## 待实现

- iPhone 网络/后台生命周期、文件保护、安装回执与实际设备资源发布验收。

✅ 制品存储作用域重绑回归：释放旧 Files 绑定后，同一模型管理器应使用新存储；关闭制品服务拒绝新请求并加入已接纳工作。

✅ 已实现：回归缓存路径字符集合后的Unicode合法路径、标点及危险路径拒绝；优化不放宽规则。

✅ 已实现：验证报告区间对应真实冷加载，暖模型／unmanaged 无事件，失败成对结束且保留原错。

## Direct container contract

Direct-input regressions cover typed request receipts, bounds, cancellation/generations, native subscriptions and unchanged authorized execution. Synthetic tests do not establish real model, UI or hardware acceptance. Current cross-module ownership is defined by the [overall design](../../MobileHarness/README.md).
