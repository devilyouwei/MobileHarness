# ModelKitHub tests

Purpose: verify the concrete Hub download integration. Design goals: reject unsafe paths, select regular files only, and distinguish network acceptance from offline regression checks.

✅ Offline tests cover directory exclusion, glob selection and unsafe/oversized remote metadata rejection.
✅ HARNESS_TEST_HUB_ENDPOINT enables an actual Silero download through the production adapter, asserts intermediate progress and required files, and cleans its temporary staging.
❌ Opt-in macOS downloads do not establish real iPhone progress rendering or lifecycle acceptance.


✅ Persisted complete-file plans resume without network access; unsafe/reserved/oversized plans fail. Production native transfer Silero downloads passed against official HF and HF-Mirror with intermediate progress. ❌ These Mac checks do not establish iPhone background/large-file resume acceptance.


✅ Fixtures use UUID/opaque runtime strings and committed database business references; concurrency, restart, invalid-ID and failure behavior remain covered.

## Identity ownership

✅ Runtime and foundation identities use opaque protocol strings or Foundation UUID; no project ID-generator dependency exists. SQLite-backed Storage publishes committed business references and App injects repositories/maps native Bluetooth identities. Tests preserve caller identity, cancellation and failure semantics. See [current storage design](../../MobileHarness/Storage/README.md) for relational allocation and persistence.
