# EnergyVADTests

Purpose: validate actual acoustic fallback scoring and managed-session cleanup. Design goals: packet-independent state, observable rejection and no model fixtures.

- ✅ Silence/energy transitions, three packet sizes, exclusive admission/reuse, reset and non-finite input rejection.
- ❌ These synthetic tests do not establish noisy-room speech discrimination; energy is not learned VAD.

## Identity ownership

✅ Runtime and foundation identities use opaque protocol strings or Foundation UUID; no project ID-generator dependency exists. SQLite-backed Storage publishes committed business references and App injects repositories/maps native Bluetooth identities. Tests preserve caller identity, cancellation and failure semantics. See [current storage design](../../MobileHarness/Storage/README.md) for relational allocation and persistence.
