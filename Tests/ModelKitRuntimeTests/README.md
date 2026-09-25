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
