# Function Contract Tests

Purpose: verify standard callable contracts independently of Gateway, execution SDKs and business modules. Design goals: concrete standard inputs, injected reporting and intrinsic metadata preservation.

✅ This target depends only on FunctionContracts. The fixture invokes one function with an ordinary FunctionInvocation and a test-owned bounded report sink.

❌ It grants no Agent permission or physical/model acceptance.

## Action timeout contract (2026-10-12)

✅ 验证基础默认 timeout、动态优先与异常不回退、无效静态值和预算上限，独立于 Gateway。


✅ Fixtures use UUID/opaque runtime strings and committed database business references; concurrency, restart, invalid-ID and failure behavior remain covered.

## Identity ownership

✅ Runtime and foundation identities use opaque protocol strings or Foundation UUID; no project ID-generator dependency exists. SQLite-backed Storage publishes committed business references and App injects repositories/maps native Bluetooth identities. Tests preserve caller identity, cancellation and failure semantics. See [current storage design](../../MobileHarness/Storage/README.md) for relational allocation and persistence.

## SQLite records migration

✅ Runtime fixtures use opaque UUID strings; committed business entities use dialog/message/task/media/device database IDs. Independent repository interfaces preserve ownership/cancellation and foundation boundaries. Completed messages (including each ReACT message) persist individually, without delta fragments or old allocator/file-index compatibility. See the project SQLite business-record plan.
