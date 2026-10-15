# NemotronTests

Purpose: validate the Core ML multilingual ASR adapter. Design goals: deterministic metadata/input/lifecycle checks and explicit real-weight acceptance.

- ✅ Strict 2240 ms metadata and prompt mapping, missing-resource availability, invalid PCM format and exclusive lease/unload checks.
- ✅ Optional scripts/test-nemotron.sh uses ignored Resources/Models/Nemotron, shared with iOS catalog provisioning, for packet parity, cancel/reload and synthetic English/Chinese checks.
- ❌ Default tests skip real weights; they do not prove phone accuracy, streaming latency or sustained stability.

✅ 2026-10-03 opt-in Mac run passed all four tests in 12.42 s with verified 2240 ms artifacts. Phone acceptance remains outstanding.


✅ Fixtures use UUID/opaque runtime strings and committed database business references; concurrency, restart, invalid-ID and failure behavior remain covered.

## Identity ownership

✅ Runtime and foundation identities use opaque protocol strings or Foundation UUID; no project ID-generator dependency exists. SQLite-backed Storage publishes committed business references and App injects repositories/maps native Bluetooth identities. Tests preserve caller identity, cancellation and failure semantics. See [current storage design](../../MobileHarness/Storage/README.md) for relational allocation and persistence.
