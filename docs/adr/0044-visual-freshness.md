# ADR 0044 — Bounded Visual Freshness

Status: accepted, 2026-09-26.

## Decision

Keep all existing Agent/Gateway/Tool boundaries. Move waiting for observation delivery off the VisionPerception inference worker into one owned publisher with one replaceable pending observation. A slow subscriber cannot block the next model operation or local skeleton delivery. No task per publication and no unbounded queue. Unexpected errors still surface terminal failure.

Replace the eight-item skeleton FIFO with one newest pending output. This Agent emits only replaceable UI.showPose state and terminal control; replacement is checked and counted. An in-flight Tool remains awaited, pending display states coalesce, and terminal control closes output before any further state can be emitted. This policy is not available to arbitrary device Actions or Tools.

Add optional maximumRefreshInterval to local frame selection. App sets 100 ms, retaining 3% change-triggered admission between refreshes. Only new captured sequences qualify; no timer or stored-frame replay. Nil preserves strict change-only behavior. The interval is measured since last accepted frame and does not guarantee inference FPS; idle power use increases compared with strict gating.

Stop clears pending slots, cancels and joins both workers. Pause stops new inference/publication dequeue while retaining one latest pending value. Existing active work may finish. Output envelopes already carry metadata only; pending publication retains a bounded parent input.

✅ Deterministic tests cover blocked publication, independent inference/display, newest-state replacement, terminal stop and freshness admission. ❌ Physical-device latency and thermal acceptance are not claimed. No model or rendering optimization is included.

Validation (2026-09-26): `scripts/check.sh` passed, including 86 IntegrationTests. All four `scripts/build-ios.sh` simulator schemes and the unsigned physical MobileHarness Release build passed. Existing opt-in real-model evaluations were not enabled. No phone installation or device performance measurement was performed.
